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
        let preferences = LocalProxyPreferences()
        expect(!preferences.isEnabled && preferences.enabledIDs.isEmpty, "module inert default")
        let usage = UsageStore([profile])
        let store = LocalProxyQueueStore(usageStore: usage)
        expect(store.phase == .stopped && !store.isEnabled && store.endpoint == nil, "construction inert")
        expect(usage.refreshCount == 0 && !store.canStart, "preview never refreshes or launches")
        expect(store.rows.first?.isEnabled == true, "new independent queue participation default")
        expect(store.rows.first?.quotaText == "Remaining: 5h 99.0% · Weekly 99.0%", "verified remaining quota labels omit unreported monthly window")
        var central = profile
        central = CodexProfile(id: "central", isSystemProfile: true, lastSnapshot: snapshot)
        let duplicateStore = LocalProxyQueueStore(usageStore: UsageStore([profile, central]))
        expect(duplicateStore.rows.isEmpty, "current identity aliases excluded")
        await store.finishForTermination()
        expect(store.canFinishTermination, "inert shutdown safe")

        let liveFixtureUsage = UsageStore([profile])
        liveFixtureUsage.isPreview = false
        let editable = LocalProxyQueueStore(usageStore: liveFixtureUsage)
        expect(!editable.isEnabled && editable.phase == .stopped && liveFixtureUsage.refreshCount == 0, "nonpreview init inert")
        editable.setOptIn(true)
        editable.setAccountPriority(id: profile.id, priority: true)
        editable.setAccountEnabled(id: profile.id, enabled: false)
        let reloaded = LocalProxyQueueStore(usageStore: liveFixtureUsage)
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
        lifecycle.cleanupConfirmedExit()
        expect(!lifecycle.leases.isEmpty && !lifecycle.canFinishTermination, "running child cannot release leases")
        child.terminate()
        child.waitUntilExit()
        lifecycle.childExited(child)
        expect(lifecycle.leases.isEmpty && lifecycle.canFinishTermination, "confirmed child exit releases only owned leases")

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
