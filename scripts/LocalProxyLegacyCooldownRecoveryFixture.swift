import Darwin
import Foundation

extension LocalProxyHostFixtures {
    @MainActor static func legacyCooldownRecoveryFixtures() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) rethrows {
            print("LEGACY_RECOVERY_CHECK \(checks + 1): \(label)")
            let result = try value()
            precondition(result, label)
            checks += 1
        }
        let root = DispatchParticipationPaths.supportDirectory()
        let directory = root.appendingPathComponent("LocalProxy", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("cooldown.json")
        let now = Date()
        let format = ISO8601DateFormatter()
        let until = format.string(from: now.addingTimeInterval(86400))
        let targetID = "legacy-target", otherID = "legacy-other"
        let unrelated: [String: Any] = ["id": otherID, "reason": "authentication", "error": ["httpStatus": 401],
            "until": until, "nested": ["number": 7, "flag": true, "values": ["a", "b"]]]
        func rows() -> [[String: Any]] {
            [["id": targetID, "reason": "credential_quota", "until": until, "recover": until, "exceeded": true],
             ["id": targetID, "model": "fixture-model", "reason": "temporary_error", "until": until, "recover": until, "exceeded": true], unrelated]
        }
        @discardableResult func write(_ records: [[String: Any]]) throws -> Data {
            let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return data
        }
        func jwt(_ claims: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: claims)
            return "fixture." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".fixture"
        }
        func auth(_ profile: CodexProfile) throws {
            try FileManager.default.createDirectory(at: profile.codexHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let account = profile.lastSnapshot!.accountID!, email = profile.lastSnapshot!.email!
            let access = try jwt(["exp": now.timeIntervalSince1970 + 3600, "iat": now.timeIntervalSince1970 - 300, "account_id": account])
            let id = try jwt(["email": email, "account_id": account])
            let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": access, "id_token": id, "account_id": account]])
            let destination = profile.codexHomeURL.appendingPathComponent("auth.json")
            try data.write(to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        let window = CodexQuotaWindowSnapshot(usedPercent: 20, resetsAt: now.addingTimeInterval(3600))
        let targetSnapshot = CodexAccountSnapshot(planType: "plus", accountID: "legacy-account", email: "legacy@example.invalid",
            fetchedAt: now.addingTimeInterval(-1), fiveHour: window, sevenDay: window)
        let target = CodexProfile(id: targetID, lastSnapshot: targetSnapshot)
        var systemSnapshot = targetSnapshot
        systemSnapshot.accountID = "central-account"; systemSnapshot.email = "central@example.invalid"
        let system = CodexProfile(id: "legacy-system", isSystemProfile: true, lastSnapshot: systemSnapshot)
        try auth(target); try auth(system)
        try write(rows())
        let usage = UsageStore([target, system]); usage.isPreview = false
        let store = LocalProxyQueueStore(usageStore: usage)
        store.preferences.enabledIDs = [targetID]; store.preferences.knownIDs = [targetID]
        store.preferences.isEnabled = true; store.isEnabled = true
        store.rebuildRows()
        func refresh() {
            usage.onRefresh = { ids in
                precondition(ids == [targetID], "only explicit target is refreshed")
                precondition(!store.canStart, "preparation must block start")
                usage.profiles[0].lastSnapshot?.fetchedAt = Date()
                usage.profiles[0].lastQuotaReadFailureAt = nil
            }
        }
        func reset() throws {
            store.cancelLegacyCooldownRecovery()
            store.process = nil; store.phase = .stopped; store.leases = [:]; store.exitCleanupID = nil
            store.preferences.enabledIDs = [targetID]
            usage.profiles = [target, system]
            try auth(target); try auth(system)
            try write(rows())
            store.rebuildRows(); refresh()
        }
        refresh()
        func prepareFromUI() async -> LocalProxyLegacyCooldownRecovery.Confirmation? {
            let ready = await withCheckedContinuation { continuation in
                store.prepareLegacyCooldownRecovery(for: targetID) { continuation.resume(returning: $0) }
            }
            return ready ? store.legacyRecoveryPreparedConfirmation : nil
        }
        expect(store.legacyCooldownRecoveryIDs == [targetID], "disk candidates survive cleared runtime cooldown state")
        expect(store.canRecoverLegacyCooldown(for: targetID), "enabled stopped identity can prepare")
        let original = try Data(contentsOf: file)
        let confirmation = await prepareFromUI()
        expect(confirmation?.recordCount == 2 && usage.refreshCount == 1, "explicit refresh produces target confirmation")
        try expect(Data(contentsOf: file) == original, "preparation never removes cooldown")
        expect(!store.canStart, "prepared native confirmation keeps start blocked")
        expect(store.recoverLegacyCooldown(for: targetID), "confirmed fresh target recovery succeeds through UI API")
        let retained = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
        expect(NSArray(array: retained).isEqual(to: [unrelated]), "every unrelated account value survives")
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("cooldown-legacy-backup-") }
        try expect(backups.count == 1 && Data(contentsOf: backups[0]) == original, "private backup keeps exact original bytes")
        var backupInfo = stat()
        expect(lstat(backups[0].path, &backupInfo) == 0 && backupInfo.st_mode & 0o777 == 0o600, "backup mode is exactly 0600")
        expect(store.legacyCooldownRecoveryIDs.isEmpty && store.preferences.enabledIDs == [targetID], "recovery preserves participation and removes candidate")
        expect(!store.commitLegacyCooldownRecovery(confirmation!), "confirmation is one shot")
        let committedBytes = try Data(contentsOf: file)
        store.cancelLegacyCooldownRecovery()
        store.cancelLegacyCooldownRecovery()
        try expect(Data(contentsOf: file) == committedBytes, "repeated close after commit cannot restore or delete cooldown records")
        try expect(Data(contentsOf: backups[0]) == original, "repeated close after commit preserves the exact saved backup")

        for error: [String: Any] in [["httpStatus": 401], ["httpStatus": 403], ["httpStatus": 429], ["httpStatus": 500],
            ["httpStatus": 0, "absent": true], ["httpStatus": 0, "credentialQuota": true], ["httpStatus": 0, "unknown": true]] {
            var records = rows(); records[1]["error"] = error
            let before = try write(records)
            expect((try? LocalProxyLegacyCooldownRecovery.prepare(at: directory, profileID: targetID)) == nil,
                "known or unrecognized model error refuses whole-account deletion: \(error)")
            try expect(Data(contentsOf: file) == before, "known error refusal does not write")
        }
        for error: Any in [NSNull(), ["httpStatus": 0], ["httpStatus": 0, "absent": false, "credentialQuota": false]] {
            var records = rows(); records[0]["error"] = error; records[1]["error"] = error
            try write(records)
            expect((try? LocalProxyLegacyCooldownRecovery.prepare(at: directory, profileID: targetID)) != nil, "missing legacy error migration remains explicitly recoverable")
        }
        var independent = rows(); independent[1]["reason"] = "rate_limit"
        try write(independent)
        expect((try? LocalProxyLegacyCooldownRecovery.prepare(at: directory, profileID: targetID)) == nil, "independent model limit is retained")

        try reset()
        let changed = await prepareFromUI()
        var newer = rows(); newer[1]["error"] = ["httpStatus": 429]
        let newerBytes = try write(newer)
        expect(changed != nil && !store.recoverLegacyCooldown(for: targetID), "write after preparation invalidates confirmation")
        try expect(Data(contentsOf: file) == newerBytes, "new 429 survives stale confirmation")
        try reset()
        let sameBytes = await prepareFromUI()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: file.path)
        expect(sameBytes != nil && !store.recoverLegacyCooldown(for: targetID), "same bytes with changed file version are refused")

        for condition in ["disabled", "stale", "credits", "failed", "wrong-target", "wrong-system", "auth", "running", "lease", "cleanup", "backup"] {
            try reset()
            let ticket = await prepareFromUI()
            precondition(ticket != nil)
            let before = try Data(contentsOf: file)
            switch condition {
            case "disabled": store.preferences.enabledIDs = []
            case "stale": usage.profiles[0].lastSnapshot?.fetchedAt = now.addingTimeInterval(-121)
            case "credits": usage.profiles[0].lastSnapshot?.fiveHour?.usedPercent = 100; usage.profiles[0].lastSnapshot?.creditBalance = "9000"
            case "failed": usage.profiles[0].lastSnapshot?.quotaReadSucceeded = false
            case "wrong-target": usage.profiles[0].lastSnapshot?.accountID = "changed-target"
            case "wrong-system": usage.profiles[1].lastSnapshot?.accountID = "changed-system"
            case "auth": var wrong = target; wrong.lastSnapshot?.accountID = "auth-other"; try auth(wrong)
            case "running": store.process = Process()
            case "lease": store.leases = ["occupied": .init(id: "occupied", profileID: targetID, requestID: "request", runID: "run")]
            case "cleanup": store.exitCleanupID = UUID()
            case "backup": LocalProxyFixtureRuntime.failLegacyBackup = true
            default: preconditionFailure()
            }
            expect(!store.recoverLegacyCooldown(for: targetID), "commit rechecks \(condition)")
            try expect(Data(contentsOf: file) == before, "\(condition) refusal retains all cooldown bytes")
            LocalProxyFixtureRuntime.failLegacyBackup = false
        }

        try reset()
        usage.onRefresh = { _ in usage.profiles[0].lastQuotaReadFailureAt = Date() }
        let failedRefresh = await prepareFromUI()
        expect(failedRefresh == nil, "failed explicit refresh cannot reuse an earlier success")
        try reset()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: file.path)
        let olderThanFile = await prepareFromUI()
        expect(olderThanFile == nil, "fresh snapshot must also be newer than legacy file")

        try reset()
        var pending: Task<LocalProxyLegacyCooldownRecovery.Confirmation?, Never>!
        await withCheckedContinuation { started in
            usage.onRefresh = { _ in started.resume() }
            pending = Task { @MainActor in await prepareFromUI() }
        }
        expect(store.isPreparingLegacyCooldownRecovery && !store.canStart, "pending explicit refresh blocks start")
        store.cancelLegacyCooldownRecovery()
        let cancelled = await pending.value
        expect(cancelled == nil, "cancel resumes pending preparation")
        expect(!store.isPreparingLegacyCooldownRecovery && store.canStart, "cancel unlocks start")
        let cancelledBytes = try Data(contentsOf: file)
        usage.profiles[0].lastSnapshot?.fetchedAt = Date()
        store.rebuildRows()
        expect(!store.recoverLegacyCooldown(for: targetID) && store.canStart,
            "late quota after close cannot recreate a cancelled confirmation")
        try expect(Data(contentsOf: file) == cancelledBytes, "late quota after close retains legacy cooldown bytes")
        try reset()
        let dismissedConfirmation = await prepareFromUI()
        precondition(dismissedConfirmation != nil)
        let dismissedBytes = try Data(contentsOf: file)
        let liveDeadline = now.addingTimeInterval(3600)
        store.accountStates[targetID] = "quota"
        store.cooldowns[targetID] = liveDeadline
        store.cancelLegacyCooldownRecovery()
        expect(store.canStart && !store.recoverLegacyCooldown(for: targetID),
            "closing a prepared confirmation releases start without committing")
        try expect(Data(contentsOf: file) == dismissedBytes, "closing confirmation never deletes cooldown records")
        expect(store.accountStates[targetID] == "quota" && store.cooldowns[targetID] == liveDeadline
            && store.preferences.enabledIDs == [targetID], "closing confirmation preserves live cooldown and participation")
        try reset()
        usage.onRefresh = { _ in
            usage.profiles[0].lastSnapshot?.fetchedAt = Date()
            store.rebuildRows()
            store.cancelLegacyCooldownRecovery()
        }
        let completed = await withCheckedContinuation { continuation in
            store.prepareLegacyCooldownRecovery(for: targetID) { continuation.resume(returning: $0) }
        }
        expect(!completed && !store.recoverLegacyCooldown(for: targetID) && store.canStart,
            "closing after resume cannot recreate a confirmation or keep start locked")
        try reset()
        let beforeCancelledRefreshes = usage.refreshCount
        let cancelledBeforeStart = await withCheckedContinuation { continuation in
            store.prepareLegacyCooldownRecovery(for: targetID) { continuation.resume(returning: $0) }
            store.cancelLegacyCooldownRecovery()
        }
        expect(!cancelledBeforeStart && usage.refreshCount == beforeCancelledRefreshes && store.canStart,
            "cancel before scheduled preparation prevents refresh and confirmation")

        try reset()
        let activity = DispatchActivityStore.live, run = UUID().uuidString, request = UUID().uuidString
        let occupied = try activity.reserveProxy(account: target.recordedAccountKey, alias: "fixture-alias", runID: run,
            requestID: request, profileID: targetID, childPID: getpid())
        let beforeRegistryRefusal = try Data(contentsOf: file)
        let registryBusy = await prepareFromUI()
        expect(registryBusy == nil, "occupied shared registry lease blocks preparation while helper is stopped")
        try expect(Data(contentsOf: file) == beforeRegistryRefusal, "registry refusal retains cooldown bytes")
        try activity.updateProxy(occupied, runID: run, requestID: request, profileID: targetID, state: "cancelled")

        try reset()
        usage.profiles[0].lastSnapshot?.email = systemSnapshot.email
        usage.profiles[0].lastSnapshot?.accountID = systemSnapshot.accountID
        try auth(usage.profiles[0]); store.rebuildRows()
        let desktop = await prepareFromUI()
        expect(desktop != nil && store.recoverLegacyCooldown(for: targetID), "enrolled Desktop same identity uses existing verified current session")
        try reset()
        usage.profiles[0].lastSnapshot?.email = systemSnapshot.email
        usage.profiles[0].lastSnapshot?.accountID = systemSnapshot.accountID
        try auth(usage.profiles[0]); store.rebuildRows()
        let desktopChanged = await prepareFromUI()
        usage.profiles[1].lastSnapshot?.accountID = "new-desktop"
        expect(desktopChanged != nil && !store.recoverLegacyCooldown(for: targetID), "Desktop identity changed after confirmation is refused")
        try reset()
        usage.profiles[0].lastSnapshot?.email = systemSnapshot.email
        usage.profiles[0].lastSnapshot?.accountID = systemSnapshot.accountID
        try auth(usage.profiles[0]); store.rebuildRows()
        let desktopAuthChanged = await prepareFromUI()
        var liveOther = system; liveOther.lastSnapshot?.accountID = "new-live-desktop"
        try auth(liveOther)
        expect(desktopAuthChanged != nil && !store.recoverLegacyCooldown(for: targetID), "changed live Desktop auth file is refused without trusting cached profile")
        try reset()
        usage.profiles[0].lastSnapshot?.email = systemSnapshot.email
        store.rebuildRows()
        let partialDesktop = await prepareFromUI()
        expect(partialDesktop == nil, "partial Desktop identity match is refused")

        try reset()
        let pure = try LocalProxyLegacyCooldownRecovery.confirm(LocalProxyLegacyCooldownRecovery.prepare(at: directory, profileID: targetID))
        var validations = 0
        do {
            _ = try LocalProxyLegacyCooldownRecovery.commit(pure) {
                validations += 1
                if validations == 2 { try write(newer) }
            }
            preconditionFailure("new writer after backup was overwritten")
        } catch { checks += 1 }
        try expect(Data(contentsOf: file) == newerBytes, "write during backup is detected before atomic replacement")
        try reset()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        expect(LocalProxyLegacyCooldownRecovery.candidates(at: directory, profileIDs: [targetID]).isEmpty, "nonprivate cooldown refuses recovery")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: backups[0])
        expect(LocalProxyLegacyCooldownRecovery.candidates(at: directory, profileIDs: [targetID]).isEmpty, "symlink cooldown refuses recovery")
        try FileManager.default.removeItem(at: file)
        expect(Darwin.link(backups[0].path, file.path) == 0, "fixture creates a hard-linked cooldown")
        expect(LocalProxyLegacyCooldownRecovery.candidates(at: directory, profileIDs: [targetID]).isEmpty, "hard-linked cooldown refuses recovery")
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 32, count: 1024 * 1024 + 1).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        expect(LocalProxyLegacyCooldownRecovery.candidates(at: directory, profileIDs: [targetID]).isEmpty, "oversized cooldown file is bounded")
        var mismatchedDeadline = rows(); mismatchedDeadline[1]["until"] = format.string(from: now.addingTimeInterval(3600))
        try write(mismatchedDeadline)
        expect(LocalProxyLegacyCooldownRecovery.candidates(at: directory, profileIDs: [targetID]).isEmpty, "independent legacy model deadline refuses whole-account recovery")
        var duplicateModel = rows(); duplicateModel.insert(duplicateModel[1], at: 1)
        try write(duplicateModel)
        expect(LocalProxyLegacyCooldownRecovery.candidates(at: directory, profileIDs: [targetID]).isEmpty, "duplicate legacy model records refuse recovery")
        try write([])
        print("local proxy legacy cooldown recovery fixtures passed (\(checks) checks; isolated files and mock refresh only)")
    }
}
