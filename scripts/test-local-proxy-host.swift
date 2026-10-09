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
        if ProcessInfo.processInfo.environment["PROXY_RELEASE_FENCE_ONLY"] == "1" {
            try await releaseFenceFixtures()
            return
        }
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
        let legacyPreferences = try JSONDecoder().decode(LocalProxyPreferences.self, from: Data(#"{"schemaVersion":1,"isEnabled":true,"order":["legacy"],"enabledIDs":["legacy"],"knownIDs":["legacy"],"priorityIDs":["legacy"],"creditFallback":true,"creditPrimaryFloor":2400,"creditSecondaryFloor":1800}"#.utf8))
        expect(legacyPreferences.lastIDs == nil && legacyPreferences.lastOverrides == nil
            && legacyPreferences.priorityIDs == ["legacy"] && legacyPreferences.creditFloors == (2400, 1800),
            "old schema1 preferences without Use last retain priority and credit floors")
        var invalidLastPreferences = legacyPreferences
        invalidLastPreferences.lastIDs = [""]
        expect(!invalidLastPreferences.validLastIDs, "empty manual-last preference ID is rejected")
        invalidLastPreferences.lastIDs = [String(repeating: "x", count: 257)]
        expect(!invalidLastPreferences.validLastIDs, "oversized manual-last preference ID is rejected")
        invalidLastPreferences.lastIDs = Set((0...1000).map { "last-\($0)" })
        expect(!invalidLastPreferences.validLastIDs, "manual-last preference count remains bounded")
        var invalidOverrides = legacyPreferences
        invalidOverrides.lastOverrides = ["": false]
        expect(!invalidOverrides.validLastOverrides, "empty override preference ID is rejected")
        invalidOverrides.lastOverrides = [String(repeating: "x", count: 257): true]
        expect(!invalidOverrides.validLastOverrides, "oversized override preference ID is rejected")
        invalidOverrides.lastOverrides = Dictionary(uniqueKeysWithValues: (0...1000).map { ("last-\($0)", false) })
        expect(!invalidOverrides.validLastOverrides, "override preference count remains bounded")
        var tierProfile = profile
        tierProfile.proTierMultiplier = 20
        expect(!LocalProxyRouting.isLastResort(tierProfile), "missing official plan is not inferred from a saved multiplier")
        tierProfile.lastSnapshot?.planType = "plus"
        expect(!LocalProxyRouting.isLastResort(tierProfile), "Plus with a stale Pro multiplier remains in the ordinary group")
        tierProfile.lastSnapshot?.planType = " Pro "
        expect(LocalProxyRouting.isLastResort(tierProfile), "official Pro20x is a last-resort account")
        expect(LocalProxyRouting.group(tierProfile, userLast: false) == 1,
            "unconfigured Pro20x inherits the last group")
        expect(LocalProxyRouting.group(tierProfile, userLast: true, lastOverride: false) == 0,
            "explicit false overrides both an old manual-last marker and the automatic Pro rule")
        expect(LocalProxyRouting.group(tierProfile, userLast: false, lastOverride: true) == 1,
            "explicit true selects the same last group as the default")
        tierProfile.proTierMultiplier = 5
        expect(!LocalProxyRouting.isLastResort(tierProfile), "known Pro5x stays in the ordinary group")
        tierProfile.proTierMultiplier = nil
        expect(LocalProxyRouting.isLastResort(tierProfile), "Pro with an unknown multiplier is conservatively last")
        tierProfile.proTierMultiplier = 7
        expect(LocalProxyRouting.isLastResort(tierProfile), "invalid Pro multiplier cannot promote a last-resort account")
        tierProfile.lastSnapshot?.planType = "prolite"
        tierProfile.proTierMultiplier = 20
        expect(!LocalProxyRouting.isLastResort(tierProfile), "Prolite stays ordinary despite stale saved 20x metadata")
        tierProfile.lastSnapshot?.planType = "pro"
        tierProfile.lastSnapshot?.quotaReadSucceeded = false
        tierProfile.officialProfile = CodexOfficialProfileSnapshot(planType: "plus")
        expect(!LocalProxyRouting.isLastResort(tierProfile), "unsuccessful quota read uses the actual official plan projection")
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
        expect(LocalProxyAdmission.quota(weeklyOnly, now: now) == nil, "weekly-only Pro subscription does not depend on credits")
        weeklyOnly.lastSnapshot?.creditBalance = "0"
        weeklyOnly.lastSnapshot?.creditBalanceUnlimited = false
        expect(LocalProxyAdmission.quota(weeklyOnly, now: now) == nil, "official weekly-only Pro without paid fallback")
        weeklyOnly.lastSnapshot?.creditBalance = "10"
        expect(LocalProxyAdmission.quota(weeklyOnly, now: now) == nil, "positive credits do not block valid weekly subscription")
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
        let stopAt60 = LocalProxyAccountPolicy(fiveHourUsedLimit: 60, allowsCredits: false)
        var capped = profile
        capped.lastSnapshot?.fiveHour?.usedPercent = 59.99
        expect(LocalProxyAdmission.quota(capped, now: now, policy: stopAt60) == nil, "below custom cap is admitted")
        capped.lastSnapshot?.fiveHour?.usedPercent = 60
        expect(LocalProxyAdmission.quota(capped, now: now, policy: stopAt60) == .usageLimit, "equality stops at custom cap")
        capped.lastSnapshot?.creditBalance = "5000"
        capped.lastSnapshot?.creditBalanceUnlimited = false
        capped.lastSnapshot?.sevenDay?.usedPercent = 100
        expect(LocalProxyAdmission.quota(capped, now: now, creditFloor: 0, allowPaidCredits: true, policy: stopAt60) == .usageLimit, "credits never bypass custom cap")
        let noCredits = LocalProxyAccountPolicy(allowsCredits: false)
        weeklyOnly.lastSnapshot?.sevenDay?.usedPercent = 100
        expect(LocalProxyAdmission.quota(weeklyOnly, now: now, policy: noCredits) == .quota, "weekly-only account stops after subscription exhaustion")
        expect(
            LocalProxyAdmission.quota(weeklyOnly, now: now, creditFloor: 0, allowPaidCredits: true, policy: noCredits) == .quota,
            "per-account credit opt-out overrides global opt-in")
        expect(LocalProxyAdmission.quota(weeklyOnly, now: now, policy: stopAt60) == .quotaUnknown, "missing 5h cannot satisfy a custom 5h cap")
        for limit in [-1.0, 100.1, .nan, .infinity] {
            expect(!LocalProxyAccountPolicy(fiveHourUsedLimit: limit).isValid, "invalid custom cap rejected")
        }
        expect(
            LocalProxyAdmission.quota(profile, now: now, policy: LocalProxyAccountPolicy(fiveHourUsedLimit: 0)) == .usageLimit, "zero cap pauses account even with remaining quota")
        expect(
            LocalProxyAdmission.creditPool([capped], activeIDs: [capped.id], policies: [capped.id: stopAt60], now: now) == nil,
            "preserved quota at a custom cap does not block other authorized credit accounts")
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
        editable.flushDisplayRows()
        expect(editable.displayRows.first?.isPriority == true, "card proxy priority appears in shared settings row")
        editable.setAccountPriority(id: profile.id, priority: false)
        editable.flushDisplayRows()
        expect(editable.displayRows.first?.isPriority == false, "settings proxy priority removal appears in shared card row")
        editable.setAccountPriority(id: profile.id, priority: true)
        expect(liveFixtureUsage.profiles == [profile] && !profile.isDispatchPriorityEnabled, "bidirectional proxy priority never changes dispatch settings")
        editable.setAccountLast(id: profile.id, last: true)
        editable.flushDisplayRows()
        expect(editable.displayRows.first?.isLast == true && editable.displayRows.first?.isPriority == false,
            "manual Use last publishes to both views and atomically clears priority")
        let lastReloaded = LocalProxyQueueStore(usageStore: liveFixtureUsage)
        expect(lastReloaded.rows.first?.isLast == true && lastReloaded.rows.first?.isFixedLast == false && lastReloaded.rows.first?.isPriority == false,
            "manual Use last persists after preference reload")
        expect(lastReloaded.creditPrimaryFloor == 2400 && lastReloaded.creditSecondaryFloor == 1800 && lastReloaded.creditFallbackEnabled,
            "manual last does not alter credit opt-in or spending floors")
        editable.setAccountPriority(id: profile.id, priority: true)
        editable.flushDisplayRows()
        expect(editable.displayRows.first?.isLast == false && editable.displayRows.first?.isPriority == true,
            "selecting priority atomically clears manual Use last in both views")
        editable.setAccountLast(id: profile.id, last: true)
        editable.setAccountLast(id: profile.id, last: false)
        editable.flushDisplayRows()
        expect(editable.displayRows.first?.isLast == false && editable.displayRows.first?.isPriority == false,
            "unchecking Use last returns an ordinary account to normal queue order")
        expect(liveFixtureUsage.profiles == [profile], "manual-last changes leave dispatch and account snapshots unchanged")
        editable.setAccountPriority(id: profile.id, priority: true)
        editable.setAccountEnabled(id: profile.id, enabled: false)
        let individualPolicy = LocalProxyAccountPolicy(fiveHourUsedLimit: 72.5, allowsCredits: false, creditPrimaryFloor: 1200, creditSecondaryFloor: 400)
        expect(editable.setAccountPolicy(id: profile.id, policy: individualPolicy), "individual cap, credit permission and floors save together")
        expect(!editable.setAccountPolicy(id: "missing", policy: individualPolicy), "unknown policy target rejected")
        let reloaded = LocalProxyQueueStore(usageStore: liveFixtureUsage)
        expect(reloaded.creditFallbackEnabled && reloaded.creditPrimaryFloor == 2400 && reloaded.creditSecondaryFloor == 1800, "credit policy persists across reload")
        expect(reloaded.rows.first?.policy == individualPolicy && reloaded.rows.first?.usesDefaultCreditFloors == false, "individual policy survives reload")
        expect(editable.setAccountPolicy(id: profile.id, policy: LocalProxyAccountPolicy()), "account can return to inherited defaults")
        paid.lastSnapshot?.creditBalanceUnlimited = false
        paid.lastSnapshot?.creditBalance = "2399"
        expect(LocalProxyAdmission.quota(paid, now: now, creditFloor: reloaded.creditPrimaryFloor, allowPaidCredits: true) == .quota, "custom first floor enforced")
        expect(LocalProxyAdmission.quota(paid, now: now, creditFloor: reloaded.creditSecondaryFloor, allowPaidCredits: true) == nil, "custom second floor enforced")
        expect(reloaded.isEnabled && reloaded.rows.first?.isEnabled == false && reloaded.rows.first?.isPriority == true, "independent queue preferences persisted")
        expect(liveFixtureUsage.profiles == [profile] && !profile.isDispatchPriorityEnabled, "dispatch profile source unchanged")
        expect(reloaded.phase == .stopped && reloaded.endpoint == nil, "saved opt-in never auto-starts")
        let preferenceRoot = DispatchParticipationPaths.supportDirectory()
        let preferenceURL = preferenceRoot.appendingPathComponent("local-proxy-queue-v1.json")
        let preferenceBaseline = try Data(contentsOf: preferenceURL)
        let failureStore = LocalProxyQueueStore(usageStore: liveFixtureUsage)
        let memoryBeforeFailure = failureStore.preferences.enabledIDs
        let membersBeforeFailure = failureStore.activeIDs
        let blockedDestination = URL(fileURLWithPath: preferenceURL.path + ".blocked")
        try FileManager.default.createDirectory(at: blockedDestination, withIntermediateDirectories: false)
        LocalProxyFixtureRuntime.failPreferenceRename = true
        failureStore.setAccountEnabled(id: profile.id, enabled: true)
        failureStore.flushDisplayRows()
        LocalProxyFixtureRuntime.failPreferenceRename = false
        try expect(Data(contentsOf: preferenceURL) == preferenceBaseline, "rename failure preserves previous preference bytes")
        expect(failureStore.preferences.enabledIDs == memoryBeforeFailure && failureStore.activeIDs == membersBeforeFailure,
            "failed commit preserves memory and running membership")
        expect(failureStore.displayRows.first?.isEnabled == false && failureStore.preferencesFailure == .save,
            "failed commit keeps published membership and persistent save error")
        failureStore.issue = nil
        expect(failureStore.preferencesFailure == .save && !failureStore.canToggleAccount(id: profile.id), "runtime issue clearing cannot erase preference failure")
        let lastFailureStore = LocalProxyQueueStore(usageStore: liveFixtureUsage)
        let priorLastIDs = lastFailureStore.preferences.lastIDs
        let priorLastOverrides = lastFailureStore.preferences.lastOverrides
        let priorPriorityIDs = lastFailureStore.preferences.priorityIDs
        LocalProxyFixtureRuntime.failPreferenceRename = true
        lastFailureStore.setAccountLast(id: profile.id, last: true)
        lastFailureStore.flushDisplayRows()
        LocalProxyFixtureRuntime.failPreferenceRename = false
        expect(lastFailureStore.preferences.lastIDs == priorLastIDs && lastFailureStore.preferences.lastOverrides == priorLastOverrides
            && lastFailureStore.preferences.priorityIDs == priorPriorityIDs,
            "failed Use last commit rolls both ordering choices back together")
        try expect(Data(contentsOf: preferenceURL) == preferenceBaseline && lastFailureStore.displayRows.first?.isLast == false
            && lastFailureStore.displayRows.first?.isPriority == true && lastFailureStore.preferencesFailure == .save,
            "failed Use last commit preserves disk bytes and the last published ordering")
        var preferenceInfo = stat()
        expect(lstat(preferenceURL.path, &preferenceInfo) == 0 && preferenceInfo.st_mode & 0o777 == 0o600,
            "successful preference commits retain mode 0600")
        try expect(FileManager.default.contentsOfDirectory(atPath: preferenceRoot.path).allSatisfy { !$0.hasPrefix(".camnext-dispatch-") },
            "success and rename failure leave no temporary preference files")
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
        editable.setAccountEnabled(id: profile.id, enabled: true)
        editable.flushDisplayRows()
        editable.refreshStatus(displayFreshResultsImmediately: true)
        var manualRefreshedProfile = profile
        manualRefreshedProfile.lastSnapshot?.fetchedAt = now.addingTimeInterval(2)
        manualRefreshedProfile.lastSnapshot?.fiveHour?.usedPercent = 44
        liveFixtureUsage.profiles = [manualRefreshedProfile]
        editable.rebuildRows()
        expect(editable.displayRows.first?.windows.first?.remaining == 56 && editable.manualRefreshTargets.isEmpty,
            "manual refresh publishes completed quota results without waiting for the routine snapshot interval")
        editable.setAccountEnabled(id: profile.id, enabled: false)
        liveFixtureUsage.profiles = [profile]
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
        var lastResortProfile = orderUsage.profiles.first { $0.id == "third" }!
        lastResortProfile.lastSnapshot?.planType = "pro"
        lastResortProfile.proTierMultiplier = 20
        let lastResortUsage = UsageStore([profile, orderUsage.profiles.first { $0.id == "second" }!, lastResortProfile])
        lastResortUsage.isPreview = false
        let lastResortOrdering = LocalProxyQueueStore(usageStore: lastResortUsage)
        lastResortOrdering.preferences.lastOverrides?.removeValue(forKey: "third")
        lastResortOrdering.preferences.lastIDs?.remove("third")
        lastResortOrdering.setAccountPriority(id: profile.id, priority: false)
        lastResortOrdering.setAccountPriority(id: "second", priority: false)
        lastResortOrdering.rebuildRows()
        expect(lastResortOrdering.rows.last?.id == "third" && lastResortOrdering.rows.last?.isLast == true
            && lastResortOrdering.rows.last?.isPriority == false && lastResortOrdering.rows.last?.isFixedLast == false,
            "Pro20x with no override defaults to a movable last choice")
        expect(lastResortOrdering.canSetAccountLast(id: "third") && lastResortOrdering.canMoveAccount(id: "third", by: -1),
            "default Pro20x can cancel Use last or move across the adjacent sorting group")
        let beforeLastResortMove = lastResortOrdering.rows.map(\.id)
        lastResortOrdering.moveAccount(id: "third", by: -1)
        var expectedLastResortMove = beforeLastResortMove
        expectedLastResortMove.swapAt(expectedLastResortMove.count - 1, expectedLastResortMove.count - 2)
        expect(lastResortOrdering.rows.map(\.id) == expectedLastResortMove
            && lastResortOrdering.preferences.lastOverrides?["third"] == false,
            "moving Pro20x up atomically persists an opt-out and the exact adjacent order")
        let movedProReload = LocalProxyQueueStore(usageStore: lastResortUsage)
        expect(movedProReload.rows.map(\.id) == expectedLastResortMove
            && movedProReload.rows.first { $0.id == "third" }?.isLast == false,
            "a moved Pro20x does not snap back after preference reload")
        lastResortOrdering.setAccountLast(id: "third", last: true)
        lastResortOrdering.setAccountLast(id: "third", last: false)
        expect(lastResortOrdering.rows.first { $0.id == "third" }?.isLast == false
            && lastResortOrdering.preferences.lastOverrides?["third"] == false
            && lastResortOrdering.preferences.lastIDs?.contains("third") != true,
            "explicitly cancelling Pro20x Use last survives its automatic plan rule")
        lastResortOrdering.setAccountPriority(id: "third", priority: true)
        expect(lastResortOrdering.rows.first?.id == "third" && lastResortOrdering.rows.first?.isPriority == true
            && lastResortOrdering.rows.first?.isLast == false,
            "explicit Pro20x priority cancels last and takes effect in the displayed order")
        lastResortOrdering.setAccountLast(id: "third", last: true)
        lastResortOrdering.setAccountLast(id: profile.id, last: true)
        lastResortOrdering.setAccountPriority(id: "second", priority: false)
        expect(lastResortOrdering.rows.first?.id == "second"
            && lastResortOrdering.rows.dropFirst().allSatisfy { $0.isLast && !$0.isPriority },
            "ordinary then effective-last is the displayed queue without contradictory priorities")
        expect(lastResortOrdering.canMoveAccount(id: "third", by: -1),
            "an effective-last account can move into the adjacent ordinary group")
        lastResortOrdering.moveAccount(id: "third", by: -1)
        expect(lastResortOrdering.rows.map(\.id) == ["third", "second", profile.id]
            && lastResortOrdering.rows.first?.isLast == false,
            "cross-group up arrow changes only the moved account's choice")
        lastResortOrdering.moveAccount(id: "second", by: 1)
        expect(lastResortOrdering.rows.map(\.id) == ["third", profile.id, "second"]
            && lastResortOrdering.rows.last?.isLast == true,
            "cross-group down arrow joins the adjacent last group and visibly moves one place")
        lastResortOrdering.setAccountLast(id: "third", last: true)
        lastResortOrdering.setAccountLast(id: "second", last: true)
        lastResortOrdering.preferences.priorityIDs.insert(profile.id)
        lastResortOrdering.rebuildRows()
        expect(lastResortOrdering.rows.allSatisfy { $0.isLast && !$0.isPriority },
            "effective-last group ignores contradictory saved priority markers")
        expect(lastResortOrdering.canMoveAccount(id: "second", by: -1), "effective-last accounts can reorder within their group")
        lastResortOrdering.moveAccount(id: "second", by: -1)
        expect(lastResortOrdering.rows.map(\.id) == ["third", "second", profile.id],
            "same-group last movement persists without hidden priority snapping it back")
        let sameLastGroupReload = LocalProxyQueueStore(usageStore: lastResortUsage)
        expect(sameLastGroupReload.rows.map(\.id) == ["third", "second", profile.id]
            && sameLastGroupReload.rows.allSatisfy { $0.isLast && !$0.isPriority },
            "three equal last-group accounts reload in their explicit persisted order")
        var promotedLastProfile = lastResortUsage.profiles.first { $0.id == "second" }!
        promotedLastProfile.lastSnapshot?.planType = "pro"
        promotedLastProfile.proTierMultiplier = 20
        lastResortUsage.profiles = [profile, promotedLastProfile, lastResortProfile]
        lastResortOrdering.rebuildRows()
        lastResortOrdering.setAccountLast(id: "second", last: false)
        expect(lastResortOrdering.rows.first { $0.id == "second" }?.isLast == false
            && lastResortOrdering.preferences.lastOverrides?["second"] == false,
            "promotion to Pro20x still permits an explicit opt-out")
        lastResortUsage.profiles = [profile, orderUsage.profiles.first { $0.id == "second" }!, lastResortProfile]
        lastResortOrdering.rebuildRows()
        expect(lastResortOrdering.rows.first { $0.id == "second" }?.isLast == false
            && lastResortOrdering.preferences.lastOverrides?["second"] == false,
            "plan changes retain the user's explicit last choice")
        lastResortOrdering.setAccountLast(id: profile.id, last: false)
        lastResortOrdering.setAccountLast(id: "second", last: false)
        lastResortOrdering.setAccountPriority(id: profile.id, priority: true)
        lastResortOrdering.setAccountPriority(id: "second", priority: true)
        let failedArrow = LocalProxyQueueStore(usageStore: lastResortUsage)
        let beforeFailedArrowRows = failedArrow.rows
        let beforeFailedArrowPreferences = failedArrow.preferences
        let beforeFailedArrowBytes = try Data(contentsOf: preferenceURL)
        LocalProxyFixtureRuntime.failPreferenceRename = true
        failedArrow.moveAccount(id: "third", by: -1)
        failedArrow.flushDisplayRows()
        LocalProxyFixtureRuntime.failPreferenceRename = false
        try expect(failedArrow.rows == beforeFailedArrowRows
            && failedArrow.preferences.order == beforeFailedArrowPreferences.order
            && failedArrow.preferences.priorityIDs == beforeFailedArrowPreferences.priorityIDs
            && failedArrow.preferences.lastIDs == beforeFailedArrowPreferences.lastIDs
            && failedArrow.preferences.lastOverrides == beforeFailedArrowPreferences.lastOverrides
            && Data(contentsOf: preferenceURL) == beforeFailedArrowBytes,
            "failed cross-group arrow rolls order, priority, override and disk back together")
        expect(failedArrow.preferencesFailure == .save && failedArrow.displayRows == beforeFailedArrowRows,
            "a failed move retains the prior published rows and reports the save failure")
        lastResortOrdering.setAccountEnabled(id: "third", enabled: false)
        lastResortOrdering.setAccountPriority(id: "third", priority: true)
        let inactivePriority = LocalProxyQueueStore(usageStore: lastResortUsage)
        expect(inactivePriority.rows.first { $0.id == "third" }.map { !$0.isEnabled && $0.isPriority && !$0.isLast } == true,
            "an inactive Pro20x can persist priority before joining the live queue")
        lastResortOrdering.setAccountLast(id: "third", last: true)
        let inactiveLast = LocalProxyQueueStore(usageStore: lastResortUsage)
        expect(inactiveLast.rows.first { $0.id == "third" }.map { !$0.isEnabled && !$0.isPriority && $0.isLast } == true,
            "an inactive Pro20x can persist Use last while keeping participation disabled")
        lastResortOrdering.setAccountEnabled(id: "third", enabled: true)
        lastResortUsage.profiles.append(central)
        lastResortOrdering.rebuildRows()
        expect(lastResortOrdering.rows.last?.id == "third" && lastResortOrdering.rows.dropLast().last?.id == profile.id,
            "ordinary Desktop account precedes a last Pro20x")
        let root = DispatchParticipationPaths.supportDirectory()
        let activity = DispatchActivityStore(directory: root)
        let run = UUID().uuidString
        var request = UUID().uuidString
        let id = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run, requestID: request, profileID: profile.id, childPID: getpid())
        func pythonInterop(_ mode: String, lease: String) async throws -> [String: Any] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROXY_FIXTURE_PYTHON"]!)
            child.arguments = [ProcessInfo.processInfo.environment["PROXY_FIXTURE_INTEROP"]!, mode, lease]
            let output = Pipe()
            child.standardOutput = output
            // Foundation waits can pump a nested main run loop. Run fixture
            // subprocess work outside the main actor's active Swift task.
            let terminationStatus = try await Task.detached {
                try child.run()
                child.waitUntilExit()
                return child.terminationStatus
            }.value
            expect(terminationStatus == 0, "Python registry interop stage")
            let result = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
            expect(result["ok"] as? Bool == true, "Python registry stage result")
            checks += result["checks"] as? Int ?? 0
            return result
        }
        try activity.updateProxy(id, runID: run, requestID: request, profileID: profile.id, state: "running")
        let pythonHeld = try await pythonInterop("native-active", lease: id)["leaseID"] as! String
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
        _ = try await pythonInterop("release-python", lease: pythonHeld)
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
        _ = try await pythonInterop("native-uncertain", lease: id)
        try activity.finishStoppedProxyRuns()
        let uncertain = try activity.read()
        expect(uncertain.leases.first?.occupied == true, "uncertainty retains lease for live owner")
        try activity.updateProxy(id, runID: run, requestID: request, profileID: profile.id, state: "accepted")
        let released = try activity.read()
        expect(released.leases.first?.occupied == false, "bound release")
        _ = try await pythonInterop("native-released", lease: id)
        let maintenanceRequestID = UUID().uuidString
        let maintenanceLease = try activity.reserveProxy(
            account: "fixture-account", alias: "fixture-alias", runID: run, requestID: maintenanceRequestID,
            profileID: profile.id, childPID: getpid())
        func maintenanceRequest(
            command: String = "heartbeat", key: String = "maintenance-key", runID: String? = nil,
            requestID: String? = nil, profileID: String? = nil, leaseID: String? = nil
        ) -> LocalProxyRequest {
            LocalProxyRequest(schemaVersion: 1, runID: runID ?? run, key: key, command: command,
                requestID: requestID ?? maintenanceRequestID, profileID: profileID ?? profile.id,
                leaseID: leaseID ?? maintenanceLease)
        }
        func maintain(_ value: LocalProxyRequest) -> LocalProxyReply {
            LocalProxyQueueStore.maintainLease(value, run: run, key: "maintenance-key",
                permittedProfiles: [profile.id], activity: activity)
        }
        expect(maintain(maintenanceRequest()).ok, "off-main maintenance persists the exact lease")
        let beforeInvalidMaintenance = try Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName))
        for invalid in [
            maintenanceRequest(key: "wrong-key"), maintenanceRequest(runID: UUID().uuidString),
            maintenanceRequest(requestID: UUID().uuidString), maintenanceRequest(profileID: "missing"),
            maintenanceRequest(leaseID: UUID().uuidString), maintenanceRequest(command: "acquire"),
        ] {
            expect(!maintain(invalid).ok, "maintenance rejects a mismatched control identity or lease tuple")
        }
        try expect(Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName)) == beforeInvalidMaintenance,
            "invalid maintenance never changes persisted ownership")
        expect(maintain(maintenanceRequest(command: "release")).ok, "off-main release is committed before its reply")
        expect(!maintain(maintenanceRequest()).ok, "heartbeat cannot revive an accepted lease")
        try activity.updateProxy(maintenanceLease, runID: run, requestID: maintenanceRequestID,
            profileID: profile.id, state: "cancelled", allowTerminalCleanup: true)
        try expect(try activity.read().leases.first { $0.leaseId == maintenanceLease }?.state == "accepted",
            "confirmed-exit cleanup preserves an already committed terminal outcome")
        // This independent registry unit has no QueueStore mirror/refresh owner.
        // Finish only its own local fence; later lifecycle tests use this same
        // synthetic run/profile and must not inherit its completed unit state.
        localProxyReleaseFence.clear(runID: run, requestID: maintenanceRequestID,
            profileID: profile.id, leaseID: maintenanceLease)
        expect(!localProxyReleaseFence.contains(runID: run, profileID: profile.id),
            "standalone maintenance fixture retires only its completed exact fence")
        do {
            try activity.updateProxy(maintenanceLease, runID: run, requestID: maintenanceRequestID,
                profileID: profile.id, state: "running", allowTerminalCleanup: true)
            preconditionFailure("terminal cleanup revived a lease")
        } catch { checks += 1 }
        do {
            try activity.updateProxy(maintenanceLease, runID: UUID().uuidString, requestID: maintenanceRequestID,
                profileID: profile.id, state: "cancelled", allowTerminalCleanup: true)
            preconditionFailure("terminal cleanup accepted a foreign run")
        } catch { checks += 1 }
        let tombstoneRequest = UUID().uuidString
        let tombstone = try activity.abandonProxy(runID: run, requestID: tombstoneRequest, profileID: profile.id)
        expect(tombstone == .notReserved, "resolve before reserve durably denies late acquire")
        do {
            _ = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run, requestID: tombstoneRequest, profileID: profile.id, childPID: getpid())
            preconditionFailure("late reserve crossed tombstone")
        } catch DispatchActivityStore.Failure.acquireAbandoned { checks += 1 }
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
        } catch DispatchActivityStore.Failure.acquireAbandoned { checks += 1 }
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
        lifecycle.setCreditFallback(false)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try await Task.detached { try child.run() }.value
        defer { if child.isRunning { child.terminate() } }
        lifecycle.process = child
        lifecycle.phase = .running
        lifecycle.runID = run
        lifecycle.controlKey = "fixture-secret"
        lifecycle.activeIDs = [profile.id]
        lifecycle.registeredPool[profile.id] = LocalProxyQueueStore.PoolBinding(
            home: profile.codexHomeURL, account: profile.recordedAccountKey, accountID: profile.lastSnapshot!.accountID!)
        let policySnapshotID = UUID().uuidString
        func orderReply(_ requestID: String) async -> LocalProxyReply {
            await lifecycle.handle(LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret",
                command: "order", requestID: requestID, profileID: profile.id, leaseID: nil))
        }
        let oldPolicy = await orderReply(policySnapshotID)
        expect(oldPolicy.ok && oldPolicy.creditFallback == false, "order snapshots disabled credit fallback")
        lifecycle.setCreditFallback(true)
        let newPolicy = await orderReply(UUID().uuidString)
        expect(newPolicy.ok && newPolicy.creditFallback == true, "new request sees enabled credit fallback")
        let repeatedPolicy = await orderReply(policySnapshotID)
        expect(repeatedPolicy.ok && repeatedPolicy.creditFallback == false, "same request retains original credit policy snapshot")
        var changedRunningAccount = profile
        changedRunningAccount.lastSnapshot?.accountID = "changed-running-account"
        isolatedUsage.profiles[0] = changedRunningAccount
        lifecycle.rebuildRows()
        expect(lifecycle.hasStaleRunningBinding(for: profile.id) && !lifecycle.canEditPolicy(for: profile.id),
            "changed running account explains why its policy editor is locked")
        isolatedUsage.profiles[0] = profile
        lifecycle.rebuildRows()
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
        HubConsoleModel.fixtureOnWarmUp = {
            warmUpEntered = true
            Thread.sleep(forTimeInterval: 1.2)
        }
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
        // A release ACK commits the registry row off-main, while its quota
        // refresh marker is installed by the delayed MainActor cleanup.
        // Paid admission must stay fail-closed in that interval.
        let fencedRequest = UUID().uuidString
        let fencedLease = try activity.reserveProxy(
            account: "fenced-account", alias: "fenced-alias", runID: run, requestID: fencedRequest,
            profileID: profile.id, childPID: child.processIdentifier)
        lifecycle.leases[fencedLease] = LocalProxyQueueStore.Lease(
            id: fencedLease, profileID: profile.id, requestID: fencedRequest, runID: run)
        lifecycle.balanceRefreshLeases.insert(fencedLease)
        let fencedRelease = LocalProxyQueueStore.maintainLease(
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: "release",
                requestID: fencedRequest, profileID: profile.id, leaseID: fencedLease),
            run: run, key: "fixture-secret", permittedProfiles: [profile.id], activity: activity)
        expect(fencedRelease.ok && lifecycle.leases[fencedLease] != nil,
            "release ACK can precede delayed UI cleanup")
        let blockedCredit = await fixtureHandle(lifecycle, LocalProxyRequest(
            schemaVersion: 1, runID: run, key: "fixture-secret", command: "acquire_credit_primary",
            requestID: UUID().uuidString, profileID: profile.id, leaseID: nil))
        if traceChecks { print("FENCE_DIAGNOSTIC blockedCredit=\(blockedCredit.error ?? "none") mirror=\(lifecycle.leases[fencedLease] != nil)") }
        expect(blockedCredit.error == "quota_unknown" && lifecycle.leases[fencedLease] != nil,
            "paid admission stays closed until release refresh cleanup crosses the fence")
        lifecycle.completeLeaseRelease(LocalProxyRequest(
            schemaVersion: 1, runID: run, key: "fixture-secret", command: "release",
            requestID: fencedRequest, profileID: profile.id, leaseID: fencedLease))
        if traceChecks { print("FENCE_DIAGNOSTIC afterCleanup pending=\(localProxyReleaseFence.contains(runID: run, profileID: profile.id)) mirror=\(lifecycle.leases[fencedLease] != nil) refreshBarrier=\(lifecycle.creditRefreshAfter[profile.id] != nil)") }
        expect(!localProxyReleaseFence.contains(runID: run, profileID: profile.id)
            && lifecycle.leases[fencedLease] == nil && lifecycle.creditRefreshAfter[profile.id] != nil,
            "release cleanup replaces the ACK fence with a verified-balance refresh barrier")
        let afterFenceCredit = await fixtureHandle(lifecycle, LocalProxyRequest(
            schemaVersion: 1, runID: run, key: "fixture-secret", command: "acquire_credit_primary",
            requestID: UUID().uuidString, profileID: profile.id, leaseID: nil))
        expect(afterFenceCredit.error == "quota_unknown",
            "release cleanup cannot authorize paid admission from a pre-release snapshot")
        for index in isolatedUsage.profiles.indices where lifecycle.activeIDs.contains(isolatedUsage.profiles[index].id) {
            isolatedUsage.profiles[index].lastSnapshot?.fetchedAt = Date()
        }
        let afterFreshBalance = await fixtureHandle(lifecycle, LocalProxyRequest(
            schemaVersion: 1, runID: run, key: "fixture-secret", command: "acquire_credit_primary",
            requestID: UUID().uuidString, profileID: profile.id, leaseID: nil))
        expect(afterFreshBalance.error == "subscription_pending",
            "paid admission can evaluate again only after a snapshot newer than the release barrier")
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
        desktopOrdering.setAccountLast(id: "third", last: true)
        desktopOrdering.flushDisplayRows()
        let manualLastRequestID = UUID().uuidString
        let manualLastReply = await desktopOrdering.handle(LocalProxyRequest(
            schemaVersion: 1, runID: run, key: "fixture-secret", command: "order", requestID: manualLastRequestID,
            profileID: profile.id, leaseID: nil))
        expect(manualLastReply.deferredIDs == ["third"] && manualLastReply.order?.last == "third",
            "new live request captures manual-last ordering behind the ordinary Desktop account")
        let frozenBeforeLast = await desktopOrdering.handle(priorityRequest)
        expect(frozenBeforeLast.order == prioritized.order && frozenBeforeLast.deferredIDs?.isEmpty == true,
            "manual-last edit cannot rewrite an existing request's ordering groups")
        expect(desktopOrdering.leases[held]?.requestID == request && desktopOrderUsage.refreshCount == refreshesBeforeOrdering,
            "live manual-last edit preserves the held request and does not refresh or switch accounts")
        try expect(Data(contentsOf: root.appendingPathComponent("dispatch-activity-v1.json")) == registryBeforeOrdering,
            "manual-last edit does not change the persisted active lease")
        desktopOrdering.setAccountPriority(id: "third", priority: true)
        _ = await desktopOrdering.handle(LocalProxyRequest(
            schemaVersion: 1, runID: run, key: "fixture-secret", command: "order_end", requestID: manualLastRequestID,
            profileID: "", leaseID: nil))
        expect(desktopOrdering.canMoveAccount(id: "second", by: -1), "arrows can explicitly cross adjacent priority tiers")
        desktopOrdering.moveAccount(id: "second", by: -1)
        let arrowPriorityRequestID = UUID().uuidString
        let arrowPriority = await desktopOrdering.handle(LocalProxyRequest(
            schemaVersion: 1, runID: run, key: "fixture-secret", command: "order", requestID: arrowPriorityRequestID,
            profileID: profile.id, leaseID: nil))
        expect(arrowPriority.order == ["second", "third", profile.id]
            && desktopOrdering.rows.first?.isPriority == true && desktopOrdering.rows.first?.isLast == false,
            "live cross-priority arrow updates the moved choice and the new RPC order together")
        let frozenBeforeArrow = await desktopOrdering.handle(priorityRequest)
        expect(frozenBeforeArrow.order == prioritized.order,
            "cross-priority arrow preserves the existing request's immutable order")
        _ = await desktopOrdering.handle(LocalProxyRequest(
            schemaVersion: 1, runID: run, key: "fixture-secret", command: "order_end", requestID: arrowPriorityRequestID,
            profileID: "", leaseID: nil))
        desktopOrdering.moveAccount(id: "second", by: 1)
        desktopOrdering.setAccountPriority(id: "second", priority: false)
        desktopOrdering.setAccountEnabled(id: "second", enabled: false)
        expect(desktopOrdering.rows.first(where: { $0.id == "second" })?.isEnabled == false,
            "one active account cannot lock an unrelated account's participation")
        let orderAfterRemoval = await desktopOrdering.handle(priorityRequest)
        expect(orderAfterRemoval.order == prioritized.order,
            "participation edits preserve an existing request's order")
        expect(desktopOrdering.setCreditFloors(primary: 2500, secondary: 1800), "running credit floors persist for new admissions")
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
        let deferredRelease = LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret",
            command: "release", requestID: request, profileID: profile.id, leaseID: held)
        let committedRelease = LocalProxyQueueStore.maintainLease(deferredRelease, run: run, key: "fixture-secret",
            permittedProfiles: [profile.id], activity: activity)
        expect(committedRelease.ok && lifecycle.leases[held] != nil,
            "off-main release can commit before its MainActor cleanup")
        lifecycle.balanceRefreshLeases.insert(held)
        let refreshesBeforeExit = isolatedUsage.refreshCount
        child.terminate()
        await Task.detached { child.waitUntilExit() }.value
        LocalProxyFixtureRuntime.failFirstTerminalCleanup = true
        lifecycle.childExited(child)
        expect(lifecycle.leases.isEmpty && lifecycle.canFinishTermination, "confirmed child exit releases only owned leases")
        expect(!LocalProxyFixtureRuntime.failFirstTerminalCleanup && lifecycle.phase == .failed && lifecycle.canEdit,
            "successful batch cleanup reconciles the contended terminal UI mirror")
        lifecycle.completeLeaseRelease(deferredRelease)
        expect(isolatedUsage.refreshCount == refreshesBeforeExit && lifecycle.leases.isEmpty,
            "late release UI cleanup after exit cannot duplicate quota refresh")
        let newRun = UUID().uuidString
        lifecycle.runID = newRun
        lifecycle.leases[held] = LocalProxyQueueStore.Lease(id: held, profileID: profile.id,
            requestID: UUID().uuidString, runID: newRun)
        lifecycle.completeLeaseRelease(deferredRelease)
        expect(lifecycle.leases[held]?.runID == newRun,
            "old-run release callback cannot remove a new-run lease")
        lifecycle.leases = [:]
        lifecycle.runID = nil
        expect(!lifecycle.requiresStopConfirmation, "confirmed exit clears interruption consent")

        // A busy proxy accepts membership changes for subsequent requests;
        // existing order snapshots and leases remain independently valid.
        let memberA = CodexProfile(id: "member-a", lastSnapshot: snapshot)
        var memberB = CodexProfile(id: "member-b", lastSnapshot: secondSnapshot)
        memberB.lastSnapshot?.planType = "pro"
        memberB.proTierMultiplier = 20
        let memberUsage = UsageStore([memberA, memberB, central])
        memberUsage.isPreview = false
        let membershipStore = LocalProxyQueueStore(usageStore: memberUsage)
        let membershipChild = Process()
        membershipChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
        membershipChild.arguments = ["30"]
        try await Task.detached { try membershipChild.run() }.value
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
        let liveFailure = LocalProxyQueueStore(usageStore: memberUsage)
        liveFailure.process = membershipChild
        liveFailure.phase = .running
        liveFailure.registeredPool = membershipStore.registeredPool
        liveFailure.activeIDs = membershipStore.activeIDs
        liveFailure.setAccountEnabled(id: memberA.id, enabled: true)
        liveFailure.flushDisplayRows()
        expect(liveFailure.displayRows.first(where: { $0.id == memberA.id })?.isEnabled == true, "live save failure fixture starts with enabled participant")
        let livePreferenceBytes = try Data(contentsOf: preferenceURL)
        let liveIDs = liveFailure.activeIDs
        LocalProxyFixtureRuntime.failPreferenceRename = true
        liveFailure.setAccountEnabled(id: memberA.id, enabled: false)
        liveFailure.flushDisplayRows()
        LocalProxyFixtureRuntime.failPreferenceRename = false
        expect(liveFailure.activeIDs == liveIDs && liveFailure.displayRows.first(where: { $0.id == memberA.id })?.isEnabled == true,
            "real precommit rename failure preserves live membership and display")
        try expect(Data(contentsOf: preferenceURL) == livePreferenceBytes, "live failed save preserves disk bytes")
        liveFailure.process = nil
        func memberRequest(_ command: String, id: String, profileID: String? = nil) -> LocalProxyRequest {
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fixture-secret", command: command,
                requestID: id, profileID: profileID ?? memberA.id, leaseID: nil)
        }
        let firstMemberRequest = UUID().uuidString
        let initialMembers = await membershipStore.handle(memberRequest("order", id: firstMemberRequest))
        expect(initialMembers.ok && Set(initialMembers.order ?? []) == [memberA.id, memberB.id] && membershipStore.membershipChangeWaiting,
            "new request freezes verified participants independently of queue edits")
        expect(initialMembers.lastResortIDs?.isEmpty == true && initialMembers.deferredIDs == [memberB.id],
            "host order places a default Pro20x in the effective last group")
        let encodedMembers = try JSONSerialization.jsonObject(with: JSONEncoder().encode(initialMembers)) as! [String: Any]
        expect((encodedMembers["lastResortIDs"] as? [String])?.isEmpty == true
            && encodedMembers["deferredIDs"] as? [String] == [memberB.id],
            "native bridge sends the effective last metadata using the deferred group field")
        var changedMemberB = memberB
        changedMemberB.proTierMultiplier = 5
        memberUsage.profiles = [memberA, changedMemberB, central]
        membershipStore.rebuildRows()
        let sameTierSnapshot = await membershipStore.handle(memberRequest("order", id: firstMemberRequest))
        expect(sameTierSnapshot.lastResortIDs == initialMembers.lastResortIDs,
            "plan changes cannot rewrite last-resort grouping for an existing request")
        let changedTierRequest = UUID().uuidString
        let changedTierSnapshot = await membershipStore.handle(memberRequest("order", id: changedTierRequest))
        expect(changedTierSnapshot.lastResortIDs?.isEmpty == true, "next request captures the updated known Pro5x group")
        _ = await membershipStore.handle(memberRequest("order_end", id: changedTierRequest, profileID: ""))
        membershipStore.setAccountLast(id: memberB.id, last: true)
        let deferredMemberID = UUID().uuidString
        let deferredMember = await membershipStore.handle(memberRequest("order", id: deferredMemberID))
        expect(deferredMember.deferredIDs == [memberB.id] && deferredMember.lastResortIDs?.isEmpty == true,
            "host freezes the user's last choice separately from automatic Pro20x")
        let encodedDeferred = try JSONSerialization.jsonObject(with: JSONEncoder().encode(deferredMember)) as! [String: Any]
        expect(encodedDeferred["deferredIDs"] as? [String] == [memberB.id], "native encodes the manual-last metadata field used by Go")
        var promotedMember = changedMemberB
        promotedMember.proTierMultiplier = 20
        memberUsage.profiles = [memberA, promotedMember, central]
        membershipStore.rebuildRows()
        let promotedMemberID = UUID().uuidString
        let promotedMemberReply = await membershipStore.handle(memberRequest("order", id: promotedMemberID))
        expect(promotedMemberReply.lastResortIDs?.isEmpty == true && promotedMemberReply.deferredIDs == [memberB.id],
            "promoted Pro20x stays in the effective last group without a forced metadata group")
        let unchangedDeferred = await membershipStore.handle(memberRequest("order", id: deferredMemberID))
        expect(unchangedDeferred.deferredIDs == [memberB.id] && unchangedDeferred.lastResortIDs?.isEmpty == true,
            "plan promotion cannot change an older request's manual-last snapshot")
        let memberRegistryBeforeOverride = try Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName))
        let memberRefreshesBeforeOverride = memberUsage.refreshCount
        membershipStore.setAccountLast(id: memberB.id, last: false)
        let cancelledLastMemberID = UUID().uuidString
        let cancelledLastMember = await membershipStore.handle(memberRequest("order", id: cancelledLastMemberID))
        expect(cancelledLastMember.deferredIDs?.isEmpty == true && cancelledLastMember.lastResortIDs?.isEmpty == true,
            "a new RPC honors explicit Pro20x cancellation while the helper remains live")
        membershipStore.setAccountPriority(id: memberB.id, priority: true)
        let prioritizedMemberID = UUID().uuidString
        let prioritizedMember = await membershipStore.handle(memberRequest("order", id: prioritizedMemberID))
        expect(prioritizedMember.order == [memberB.id, memberA.id] && prioritizedMember.deferredIDs?.isEmpty == true,
            "a new RPC can use an explicitly prioritized Pro20x before ordinary accounts")
        let frozenDefaultMember = await membershipStore.handle(memberRequest("order", id: firstMemberRequest))
        expect(frozenDefaultMember.order == initialMembers.order && frozenDefaultMember.deferredIDs == initialMembers.deferredIDs,
            "live Pro20x overrides never rewrite an existing request's default-last snapshot")
        let overrideReload = LocalProxyQueueStore(usageStore: memberUsage)
        expect(overrideReload.preferences.lastOverrides?[memberB.id] == false
            && overrideReload.rows.first { $0.id == memberB.id }.map { $0.isPriority && !$0.isLast } == true,
            "live Pro20x priority and explicit false survive reload with the same official plan")
        try expect(memberUsage.refreshCount == memberRefreshesBeforeOverride && membershipChild.isRunning
            && Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName)) == memberRegistryBeforeOverride,
            "live priority and last overrides preserve the helper, quotas and activity registry")
        _ = await membershipStore.handle(memberRequest("order_end", id: cancelledLastMemberID, profileID: ""))
        _ = await membershipStore.handle(memberRequest("order_end", id: prioritizedMemberID, profileID: ""))
        _ = await membershipStore.handle(memberRequest("order_end", id: deferredMemberID, profileID: ""))
        _ = await membershipStore.handle(memberRequest("order_end", id: promotedMemberID, profileID: ""))
        memberUsage.profiles = [memberA, changedMemberB, central]
        membershipStore.rebuildRows()
        membershipStore.setAccountLast(id: memberB.id, last: false)
        expect(membershipStore.canToggleAccount(id: memberA.id), "in-flight request permits future membership removal")
        membershipStore.setAccountEnabled(id: memberA.id, enabled: false)
        expect(!membershipStore.activeIDs.contains(memberA.id) && membershipChild.isRunning,
            "member leaves new requests without stopping the helper")
        for command in ["acquire", "acquire_credit_primary", "acquire_credit_secondary",
            "acquire_desktop", "acquire_desktop_credit_primary", "acquire_desktop_credit_secondary"] {
            let refused = await membershipStore.handle(memberRequest(command, id: firstMemberRequest, profileID: memberA.id))
            expect(refused.error == "not_participating" && refused.accessToken == nil && refused.leaseID == nil,
                "saved removal blocks an old waiting request in every admission stage")
        }
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
        await Task.detached { membershipChild.waitUntilExit() }.value
        membershipStore.process = nil
        membershipStore.phase = .stopped

        let uncertainChild = Process()
        uncertainChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
        uncertainChild.arguments = ["30"]
        try await Task.detached { try uncertainChild.run() }.value
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
        await Task.detached { uncertainChild.waitUntilExit() }.value
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
        runtimeStore.consume(Data("{\"event\":\"error\",\"errorCode\":\"lease_acquire_unknown\",\"errorDetail\":\"timeout\",\"resolutionDetail\":\"control_busy\"}".utf8), run: activeRun)
        for _ in 0..<100 {
            if runtimeStore.canFinishTermination { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        expect(runtimeStore.canFinishTermination && runtimeStore.endpoint == nil, "unknown acquisition stops child before release")
        expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("LocalProxy").path), "cooldowns directory survives stop")
        let issueLog = try String(contentsOf: issueLogURL, encoding: .utf8)
        expect(issueLog.contains("\"phase\":\"control_failure\""), "confirmed control failure records separately")
        expect(issueLog.contains("lease_acquire_unknown: timeout; resolution: control_busy"),
            "native diagnostic preserves original failure and distinguishes resolver refusal")
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
        creditStore.setAccountEnabled(id: profile.id, enabled: true)
        creditStore.setCreditFallback(true)
        creditStore.setCreditFloors(primary: 2400, secondary: 1800)
        let creditChild = Process()
        creditChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
        creditChild.arguments = ["30"]
        try await Task.detached { try creditChild.run() }.value
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
        creditStore.setAccountEnabled(id: subscriptionPeer.id, enabled: true)
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
        for stage in ["reserve", "running", "warmup"] {
            let entered = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            let pause: () -> Void = {
                entered.signal()
                _ = resume.wait(timeout: .now() + 5)
            }
            if stage == "reserve" { LocalProxyFixtureRuntime.afterReserve = pause }
            if stage == "running" { LocalProxyFixtureRuntime.afterRunning = pause }
            if stage == "warmup" {
                HubConsoleModel.fixtureOnWarmUp = { _ = creditStore.setCreditFloors(primary: 2450, secondary: 1800) }
            }
            let changingRequest = creditRequest("acquire_credit_primary", requestID: UUID().uuidString)
            let pending = Task { await fixtureHandle(creditStore, changingRequest) }
            if stage != "warmup" {
                let paused = await Task.detached { Self.waitForReserve(entered) }.value
                expect(paused, "policy edit fixture pauses at \(stage)")
                expect(creditStore.setCreditFloors(primary: 2450, secondary: 1800), "policy edit persists during \(stage)")
                resume.signal()
            }
            let reply = await pending.value
            LocalProxyFixtureRuntime.afterReserve = nil
            LocalProxyFixtureRuntime.afterRunning = nil
            HubConsoleModel.fixtureOnWarmUp = nil
            expect(
                reply.error == "policy_changed" && reply.resolution == "abandoned" && reply.accessToken == nil && creditStore.leases.isEmpty,
                "policy change across \(stage) rolls back without releasing credentials")
            expect(creditStore.setCreditFloors(primary: 2400, secondary: 1800), "restore fixture floors after policy race")
            try expect(try activity.isProxyAcquireAbandoned(runID: creditRun, requestID: changingRequest.requestID, profileID: profile.id),
                "policy rollback across \(stage) retains durable deny marker")
            let replay = await fixtureHandle(creditStore, changingRequest)
            expect(replay.error == "acquire_abandoned" && replay.resolution == "abandoned" && replay.accessToken == nil,
                "same tuple after \(stage) rollback has explicit terminal refusal")
            let nextRequest = creditRequest("acquire_credit_primary", requestID: UUID().uuidString)
            let recovered = await fixtureHandle(creditStore, nextRequest)
            expect(recovered.ok && recovered.leaseID != nil, "fresh request after \(stage) rollback can recover")
            let release = await fixtureHandle(creditStore, creditRequest("release", requestID: nextRequest.requestID, leaseID: recovered.leaseID))
            expect(release.ok, "fresh request after \(stage) rollback releases normally")
            creditUsage.profiles[0].lastSnapshot?.fetchedAt = Date()
        }
        HubConsoleModel.fixtureAvailability = .busy
        let warmupBusyRequest = creditRequest("acquire_credit_primary", requestID: UUID().uuidString)
        let warmupBusy = await fixtureHandle(creditStore, warmupBusyRequest)
        expect(warmupBusy.error == "busy" && warmupBusy.resolution == "abandoned" && creditStore.leases.isEmpty,
            "busy Hub after reservation explicitly confirms rollback")
        HubConsoleModel.fixtureAvailability = .idle
        let warmupReplay = await fixtureHandle(creditStore, warmupBusyRequest)
        expect(warmupReplay.error == "acquire_abandoned" && warmupReplay.resolution == "abandoned" && warmupReplay.accessToken == nil,
            "restored Hub cannot reuse rolled-back tuple")
        let creditOptOut = LocalProxyAccountPolicy(allowsCredits: false)
        for stage in ["reserve", "running", "warmup"] {
            let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
            let pause: () -> Void = {
                entered.signal()
                _ = resume.wait(timeout: .now() + 5)
            }
            if stage == "reserve" { LocalProxyFixtureRuntime.afterReserve = pause }
            if stage == "running" { LocalProxyFixtureRuntime.afterRunning = pause }
            if stage == "warmup" {
                HubConsoleModel.fixtureOnWarmUp = { creditStore.setAccountEnabled(id: profile.id, enabled: false) }
            }
            let pending = Task { await fixtureHandle(creditStore,
                creditRequest("acquire_credit_primary", requestID: UUID().uuidString)) }
            if stage != "warmup" {
                let paused = await Task.detached { Self.waitForReserve(entered) }.value
                expect(paused, "participation removal pauses at \(stage)")
                creditStore.setAccountEnabled(id: profile.id, enabled: false)
                resume.signal()
            }
            let reply = await pending.value
            LocalProxyFixtureRuntime.afterReserve = nil
            LocalProxyFixtureRuntime.afterRunning = nil
            HubConsoleModel.fixtureOnWarmUp = nil
            expect(reply.error == "not_participating" && reply.accessToken == nil && creditStore.leases.isEmpty,
                "removal across \(stage) rolls back without delivering credentials")
            creditStore.setAccountEnabled(id: profile.id, enabled: true)
        }
        expect(creditStore.setAccountPolicy(id: profile.id, policy: creditOptOut), "live per-account credit opt-out saves")
        let optedOut = await fixtureHandle(creditStore, creditRequest("acquire_credit_primary", requestID: UUID().uuidString))
        expect(optedOut.error == "quota" && optedOut.accessToken == nil, "live individual credit opt-out blocks paid admission")
        expect(creditStore.setAccountPolicy(id: profile.id, policy: LocalProxyAccountPolicy()), "restore individual policy")
        let firstCreditRequest = UUID().uuidString
        let firstCredit = await fixtureHandle(creditStore, creditRequest("acquire_credit_primary", requestID: firstCreditRequest))
        expect(firstCredit.ok && firstCredit.leaseID != nil, "host admits balance above configured primary floor")
        expect(creditStore.setAccountPolicy(id: profile.id, policy: LocalProxyAccountPolicy(allowsCredits: false)), "rules remain editable with an admitted request")
        expect(firstCredit.leaseID.map { creditStore.leases[$0]?.isAdmitted == true } == true, "editing rules preserves an already admitted request")
        expect(creditStore.setAccountPolicy(id: profile.id, policy: LocalProxyAccountPolicy()), "restore active fixture policy")
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
        expect(creditStore.setCreditFloors(primary: 100, secondary: 0), "running policy can change for subsequent requests")
        creditChild.terminate()
        await Task.detached { creditChild.waitUntilExit() }.value
        creditStore.childExited(creditChild)
        HubConsoleModel.fixtureAvailability = .unavailable
        let refreshStarted = DispatchSemaphore(value: 0)
        let releaseRefresh = DispatchSemaphore(value: 0)
        let refreshFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            CodexCredentialAccessGate.lock.lock()
            refreshStarted.signal()
            _ = releaseRefresh.wait(timeout: .now() + 5)
            CodexCredentialAccessGate.lock.unlock()
            refreshFinished.signal()
        }
        expect(refreshStarted.wait(timeout: .now() + 2) == .success, "fixture quota refresh holds global credential gate")
        let gateWaitStart = ProcessInfo.processInfo.systemUptime
        let duringRefresh = try LocalProxyCredentialReader.read(profile: profile, system: systemProfile, now: now)
        expect(duringRefresh.accountID == "account-fixture", "stable credential snapshot remains usable during unrelated refresh")
        expect(ProcessInfo.processInfo.systemUptime - gateWaitStart < 0.5, "read-only admission does not wait on global quota refresh")
        releaseRefresh.signal()
        expect(refreshFinished.wait(timeout: .now() + 1) == .success, "fixture releases credential gate")
        try FileManager.default.removeItem(at: profileFile)
        try FileManager.default.createSymbolicLink(at: profileFile, withDestinationURL: centralFile)
        do {
            _ = try LocalProxyCredentialReader.read(profile: profile, system: systemProfile, now: now)
            preconditionFailure("symlink credentials")
        } catch { checks += 1 }
        print("PASS: \(checks) local proxy host synthetic checks; no live profiles, network or app launch")
    }
}

extension LocalProxyHostFixtures {
    /// Short, deterministic release races. Uses only synthetic files/children.
    @MainActor static func releaseFenceFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) rethrows {
            let result = try value()
            precondition(result, label)
            checks += 1
            print("RELEASE_FENCE_CHECK \(checks): \(label)")
        }
        let root = DispatchParticipationPaths.supportDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let activity = DispatchActivityStore.live
        let now = Date()
        let five = CodexQuotaWindowSnapshot(usedPercent: 100, resetsAt: now.addingTimeInterval(18000))
        let seven = CodexQuotaWindowSnapshot(usedPercent: 20, resetsAt: now.addingTimeInterval(604800))
        func profile(_ id: String) -> CodexProfile {
            CodexProfile(id: id, lastSnapshot: CodexAccountSnapshot(planType: "plus", creditBalance: "3000", creditBalanceUnlimited: false,
                accountID: "account-" + id, email: id + "@example.invalid", fetchedAt: now, fiveHour: five, sevenDay: seven))
        }
        let target = profile("fence-target"), peer = profile("fence-peer")
        var system = profile("system"); system.isSystemProfile = true
        func jwt(_ claims: [String: Any]) throws -> String {
            let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "fixture.\(encoded).fixture"
        }
        for value in [target, peer, system] {
            try FileManager.default.createDirectory(at: value.codexHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let access = try jwt(["exp": now.timeIntervalSince1970 + 3600, "iat": now.timeIntervalSince1970 - 300, "account_id": value.lastSnapshot!.accountID!])
            let token = try jwt(["email": value.lastSnapshot!.email!, "account_id": value.lastSnapshot!.accountID!])
            let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": access, "id_token": token, "account_id": value.lastSnapshot!.accountID!]])
            let url = value.codexHomeURL.appendingPathComponent("auth.json")
            try data.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let usage = UsageStore([target, peer, system]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage)
        store.setCreditFallback(true); store.setCreditFloors(primary: 2400, secondary: 1800)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; localProxyReleaseFence.clear(runID: store.runID ?? "") }
        let run = UUID().uuidString
        store.process = child; store.phase = .running; store.runID = run; store.controlKey = "fence-key"
        store.activeIDs = [target.id, peer.id]
        store.preferences.order = [target.id, peer.id]; store.preferences.enabledIDs = [target.id, peer.id]
        store.registeredPool = Dictionary(uniqueKeysWithValues: [target, peer].map {
            ($0.id, LocalProxyQueueStore.PoolBinding(home: $0.codexHomeURL, account: $0.recordedAccountKey, accountID: $0.lastSnapshot!.accountID!))
        })
        HubConsoleModel.fixtureAvailability = .idle
        store.rebuildRows()
        func release(_ requestID: String, _ leaseID: String, profileID: String = peer.id) -> LocalProxyRequest {
            LocalProxyRequest(schemaVersion: 1, runID: run, key: "fence-key", command: "release", requestID: requestID, profileID: profileID, leaseID: leaseID)
        }
        func reservePeer() throws -> LocalProxyRequest {
            let requestID = UUID().uuidString
            let lease = try activity.reserveProxy(account: peer.recordedAccountKey, alias: "peer", runID: run, requestID: requestID,
                profileID: peer.id, childPID: child.processIdentifier)
            store.leases[lease] = LocalProxyQueueStore.Lease(id: lease, profileID: peer.id, requestID: requestID, runID: run)
            store.balanceRefreshLeases.insert(lease)
            return release(requestID, lease)
        }
        // Reproduce the full-suite failure: an earlier standalone release and
        // a later release share run/profile but have independent exact fences.
        let earlierRelease = try reservePeer()
        expect(LocalProxyQueueStore.maintainLease(earlierRelease, run: run, key: "fence-key",
            permittedProfiles: [target.id, peer.id], activity: activity).ok, "earlier standalone release commits")
        let laterRelease = try reservePeer()
        expect(LocalProxyQueueStore.maintainLease(laterRelease, run: run, key: "fence-key",
            permittedProfiles: [target.id, peer.id], activity: activity).ok, "later same-profile release commits")
        store.completeLeaseRelease(laterRelease)
        expect(localProxyReleaseFence.contains(runID: run, profileID: peer.id),
            "later exact cleanup correctly retains an earlier pending fence")
        store.completeLeaseRelease(earlierRelease)
        expect(!localProxyReleaseFence.contains(runID: run, profileID: peer.id),
            "each completed fixture unit must retire its own exact fence")
        let callbackRequest = try reservePeer()
        var published = false
        try activity.updateProxy(callbackRequest.leaseID!, runID: run, requestID: callbackRequest.requestID, profileID: peer.id, state: "accepted") {
            expect(!localProxyReleaseFence.contains(runID: run, profileID: peer.id), "fence is absent before commit publisher")
            try! expect(activity.read().leases.first { $0.leaseId == callbackRequest.leaseID }?.state == "accepted", "commit callback sees durable terminal row")
            let fd = Darwin.open(root.appendingPathComponent(DispatchActivityStore.lockName).path, O_RDWR)
            defer { Darwin.close(fd) }
            expect(flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK, "commit publisher still owns registry file lock")
            localProxyReleaseFence.mark(runID: run, requestID: callbackRequest.requestID, profileID: peer.id, leaseID: callbackRequest.leaseID!)
            published = true
        }
        expect(published && localProxyReleaseFence.contains(runID: run, profileID: peer.id), "commit publishes exact fence before ACK")
        store.completeLeaseRelease(callbackRequest)
        let duplicateRelease = LocalProxyQueueStore.maintainLease(callbackRequest, run: run, key: "fence-key",
            permittedProfiles: [target.id, peer.id], activity: activity)
        expect(!duplicateRelease.ok && !localProxyReleaseFence.contains(runID: run, profileID: peer.id),
            "duplicate terminal release cannot republish a cleared fence")
        for index in usage.profiles.indices { usage.profiles[index].lastSnapshot?.fetchedAt = Date() }
        for stage in ["reserve", "running"] {
            let peerRelease = try reservePeer()
            let before = try Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName))
            let wrong = release(UUID().uuidString, peerRelease.leaseID!)
            let bad = LocalProxyQueueStore.maintainLease(wrong, run: run, key: "fence-key", permittedProfiles: [target.id, peer.id], activity: activity)
            expect(!bad.ok && !localProxyReleaseFence.contains(runID: run, profileID: peer.id), "wrong release tuple cannot publish a fence")
            try expect(Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName)) == before, "wrong release leaves registry bytes unchanged")
            LocalProxyFixtureRuntime.failActivityCommit = true
            let failed = LocalProxyQueueStore.maintainLease(peerRelease, run: run, key: "fence-key", permittedProfiles: [target.id, peer.id], activity: activity)
            LocalProxyFixtureRuntime.failActivityCommit = false
            expect(!failed.ok && !localProxyReleaseFence.contains(runID: run, profileID: peer.id), "failed registry write cannot report ACK or publish a fence")
            try expect(Data(contentsOf: root.appendingPathComponent(DispatchActivityStore.stateName)) == before, "failed commit keeps active registry bytes")
            let publish: () -> Void = {
                let reply = LocalProxyQueueStore.maintainLease(peerRelease, run: run, key: "fence-key", permittedProfiles: [target.id, peer.id], activity: activity)
                precondition(reply.ok, "deterministic peer release must commit")
            }
            if stage == "reserve" { LocalProxyFixtureRuntime.afterReserve = publish }
            else { LocalProxyFixtureRuntime.afterRunning = publish }
            let request = LocalProxyRequest(schemaVersion: 1, runID: run, key: "fence-key", command: "acquire_credit_primary",
                requestID: UUID().uuidString, profileID: target.id, leaseID: nil)
            let reply = await fixtureHandle(store, request)
            LocalProxyFixtureRuntime.afterReserve = nil; LocalProxyFixtureRuntime.afterRunning = nil
            expect(reply.error == "quota_unknown" && reply.accessToken == nil && reply.accountID == nil && reply.leaseID == nil,
                "peer release after \(stage) rejects paid credentials")
            expect(store.leases.values.allSatisfy { $0.profileID != target.id }, "paid race rolls back target reservation after \(stage)")
            store.completeLeaseRelease(wrong)
            expect(localProxyReleaseFence.contains(runID: run, profileID: peer.id), "wrong cleanup cannot clear pending exact fence")
            store.completeLeaseRelease(peerRelease)
            expect(!localProxyReleaseFence.contains(runID: run, profileID: peer.id) && store.creditRefreshAfter[peer.id] != nil,
                "correct cleanup installs balance barrier before clearing exact fence")
            let stale = await fixtureHandle(store, LocalProxyRequest(schemaVersion: 1, runID: run, key: "fence-key", command: "acquire_credit_primary",
                requestID: UUID().uuidString, profileID: target.id, leaseID: nil))
            expect(stale.error == "quota_unknown" && stale.accessToken == nil, "pre-release snapshot remains unusable after cleanup")
            for index in usage.profiles.indices { usage.profiles[index].lastSnapshot?.fetchedAt = Date() }
            let newLease = UUID().uuidString, newRequest = UUID().uuidString
            localProxyReleaseFence.mark(runID: run, requestID: newRequest, profileID: peer.id, leaseID: newLease)
            store.leases[newLease] = LocalProxyQueueStore.Lease(id: newLease, profileID: peer.id, requestID: newRequest, runID: run)
            store.completeLeaseRelease(peerRelease)
            expect(localProxyReleaseFence.contains(runID: run, profileID: peer.id), "late old cleanup cannot clear a newer lease fence")
            let otherRun = UUID().uuidString
            localProxyReleaseFence.mark(runID: otherRun, requestID: newRequest, profileID: peer.id, leaseID: newLease)
            localProxyReleaseFence.clear(runID: run)
            expect(localProxyReleaseFence.contains(runID: otherRun, profileID: peer.id), "run retirement leaves another run fence intact")
            localProxyReleaseFence.clear(runID: otherRun); store.leases.removeValue(forKey: newLease)
        }
        let admitted = await fixtureHandle(store, LocalProxyRequest(schemaVersion: 1, runID: run, key: "fence-key", command: "acquire_credit_primary",
            requestID: UUID().uuidString, profileID: target.id, leaseID: nil))
        expect(admitted.ok && admitted.accessToken != nil, "fresh post-release balance allows full strict re-evaluation")
        if let lease = admitted.leaseID {
            let saved = store.leases[lease]!
            var verifiedUnderLock = false
            try expect(activity.isProxyLeaseActive(lease, runID: run, requestID: saved.requestID,
                profileID: target.id, childPID: child.processIdentifier) {
                    let fd = Darwin.open(root.appendingPathComponent(DispatchActivityStore.lockName).path, O_RDWR)
                    defer { Darwin.close(fd) }
                    expect(flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK,
                        "final synchronous admission check shares the release commit file lock")
                    verifiedUnderLock = true
                } && verifiedUnderLock, "final active lease proof and admission use one locked snapshot")
            do {
                _ = try activity.isProxyLeaseActive(lease, runID: run, requestID: saved.requestID,
                    profileID: target.id, childPID: child.processIdentifier) { throw LocalProxyFailure.quotaUnknown }
                preconditionFailure("final admission failure was swallowed")
            } catch LocalProxyFailure.quotaUnknown {
                expect(true, "final admission failure propagates its original reason")
            }
            let released = LocalProxyQueueStore.maintainLease(release(saved.requestID, lease, profileID: target.id), run: run, key: "fence-key",
                permittedProfiles: [target.id, peer.id], activity: activity)
            expect(released.ok, "final synthetic admitted lease ends")
            store.completeLeaseRelease(release(saved.requestID, lease, profileID: target.id))
        }
        print("PASS: \(checks) deterministic release fence checks; no real account/provider")
    }
}
