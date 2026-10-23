import Darwin
import Foundation

private struct ParticipationFixtureFailure: Error { let checks: [String] }

extension LocalProxyHostFixtures {
    @MainActor static func participationFixtures() async throws {
        var checks = 0
        var failures: [String] = []
        func expect(_ value: @autoclosure () throws -> Bool, _ label: String) rethrows {
            checks += 1
            let passed = try value()
            print("PARTICIPATION_CHECK \(checks): \(passed ? "PASS" : "FAIL") \(label)")
            if !passed { failures.append(label) }
        }
        let root = DispatchParticipationPaths.supportDirectory()
        expect(root.path.contains("aigoodbro-proxy-host-fixture-"), "synthetic support directory only")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date()
        let window = CodexQuotaWindowSnapshot(usedPercent: 10, resetsAt: now.addingTimeInterval(3600))
        func profile(_ id: String, plan: String = "plus", email: String? = nil, account: String? = nil) -> CodexProfile {
            CodexProfile(
                id: id,
                lastSnapshot: .init(
                    planType: plan, creditBalance: "5000", creditBalanceUnlimited: false,
                    accountID: account ?? id + "-account", email: email ?? id + "@example.invalid", fetchedAt: now, fiveHour: window, sevenDay: window))
        }
        func requestID() -> String {
            let time = String(format: "%012llx", UInt64(Date().timeIntervalSince1970 * 1000))
            let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            return "\(time.prefix(8))-\(time.suffix(4))-7\(random.prefix(3))-a\(random.dropFirst(3).prefix(3))-\(random.dropFirst(6).prefix(12))"
        }
        func writeCredentials(_ candidate: CodexProfile) throws {
            func jwt(_ claims: [String: Any]) throws -> String {
                let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                return "fixture.\(encoded).fixture"
            }
            try FileManager.default.createDirectory(at: candidate.codexHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let account = candidate.lastSnapshot!.accountID!
            let email = candidate.lastSnapshot!.email!
            let access = try jwt(["exp": now.timeIntervalSince1970 + 3600, "iat": now.timeIntervalSince1970 - 300, "account_id": account])
            let identity = try jwt(["email": email, "account_id": account])
            let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": access, "id_token": identity, "account_id": account]])
            let file = candidate.codexHomeURL.appendingPathComponent("auth.json")
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["90"]
        try child.run()
        defer {
            HubConsoleModel.fixtureOnWarmUp = nil
            LocalProxyFixtureRuntime.afterRunning = nil
            HubConsoleModel.fixtureAvailability = .unavailable
            LocalProxyFixtureRuntime.failPreferenceRename = false
            if child.isRunning { child.terminate() }
        }
        let selected = ProcessInfo.processInfo.environment["PROXY_PARTICIPATION_SCENARIO"]
        let file = root.appendingPathComponent("local-proxy-queue-v1.json")
        let registry = root.appendingPathComponent(DispatchActivityStore.stateName)
        if selected == nil || selected == "membership" {
            var pro = profile("member-pro20", plan: "pro")
            pro.proTierMultiplier = 20
            pro.lastSnapshot?.fiveHour = nil
            let peer = profile("member-peer")
            var central = profile("member-central")
            central.isSystemProfile = true
            for candidate in [pro, peer, central] { try writeCredentials(candidate) }
            let usage = UsageStore([pro, peer, central])
            usage.isPreview = false
            let store = LocalProxyQueueStore(usageStore: usage)
            let run = UUID().uuidString
            let key = "synthetic-participation"
            store.process = child
            store.phase = .running
            store.runID = run
            store.controlKey = key
            store.registeredPool = Dictionary(
                uniqueKeysWithValues: [pro, peer].map {
                    (
                        $0.id,
                        LocalProxyQueueStore.PoolBinding(home: $0.codexHomeURL, account: $0.recordedAccountKey, accountID: $0.lastSnapshot!.accountID!)
                    )
                })
            store.activeIDs = [pro.id, peer.id]
            HubConsoleModel.fixtureAvailability = .idle
            func request(_ command: String, _ id: String, target: String? = nil, lease: String? = nil) -> LocalProxyRequest {
                .init(schemaVersion: 1, runID: run, key: key, command: command, requestID: id, profileID: target ?? pro.id, leaseID: lease)
            }
            func release(_ reply: LocalProxyReply, id: String, target: String? = nil) async {
                if let lease = reply.leaseID { _ = await store.handle(request("release", id, target: target, lease: lease)) }
            }
            let oldID = requestID()
            let initial = await store.handle(request("order", oldID))
            expect(initial.ok && initial.deferredIDs == [pro.id], "fresh Pro20x defaults to last without disabling participation")
            store.setAccountEnabled(id: pro.id, enabled: false)
            let commands = [
                "acquire", "acquire_credit_primary", "acquire_credit_secondary",
                "acquire_desktop", "acquire_desktop_credit_primary", "acquire_desktop_credit_secondary",
            ]
            for command in commands {
                let refused = await store.handle(request(command, oldID))
                print("PARTICIPATION_OBSERVED single-off \(command): ok=\(refused.ok) error=\(refused.error ?? "none") tokenReturned=\(refused.accessToken != nil)")
                expect(
                    refused.error == "not_participating" && refused.accessToken == nil && refused.leaseID == nil,
                    "single off rejects old Pro20x \(command)")
            }
            store.setAccountEnabled(id: pro.id, enabled: true)
            for command in commands {
                let refused = await store.handle(request(command, oldID))
                print("PARTICIPATION_OBSERVED off-on \(command): ok=\(refused.ok) error=\(refused.error ?? "none") tokenReturned=\(refused.accessToken != nil)")
                expect(
                    refused.error == "not_participating" && refused.accessToken == nil && refused.leaseID == nil,
                    "off/on cannot revive old Pro20x \(command)")
                await release(refused, id: oldID)
            }
            let peerReply = await store.handle(request("acquire", oldID, target: peer.id))
            expect(peerReply.ok && peerReply.accessToken != nil, "another member retains admission from the same old order")
            await release(peerReply, id: oldID, target: peer.id)
            _ = await store.handle(request("order_end", oldID, target: ""))
            let awaitedID = requestID()
            _ = await store.handle(request("order", awaitedID))
            var toggledDuringAwait = false
            HubConsoleModel.fixtureOnWarmUp = {
                toggledDuringAwait = true
                store.setAccountEnabled(id: pro.id, enabled: false)
                store.setAccountEnabled(id: pro.id, enabled: true)
            }
            let awaited = await store.handle(request("acquire", awaitedID))
            HubConsoleModel.fixtureOnWarmUp = nil
            print("PARTICIPATION_OBSERVED await-off-on: ok=\(awaited.ok) error=\(awaited.error ?? "none") tokenReturned=\(awaited.accessToken != nil)")
            expect(
                toggledDuringAwait && awaited.error == "not_participating" && awaited.accessToken == nil && awaited.leaseID == nil,
                "off/on during Hub await rejects the reserved old request before token reply")
            await release(awaited, id: awaitedID)
            try expect(
                try DispatchActivityStore.live.read().leases.allSatisfy { $0.taskId != "proxy-\(run)-\(awaitedID)" || !$0.occupied },
                "revoked await leaves no occupied reservation")
            _ = await store.handle(request("order_end", awaitedID, target: ""))
            let committedID = requestID()
            _ = await store.handle(request("order", committedID))
            let changedAfterCommit = DispatchSemaphore(value: 0)
            LocalProxyFixtureRuntime.afterRunning = {
                Task { @MainActor in
                    store.setAccountEnabled(id: pro.id, enabled: false)
                    store.setAccountEnabled(id: pro.id, enabled: true)
                    changedAfterCommit.signal()
                }
                _ = changedAfterCommit.wait(timeout: .now() + 3)
            }
            let committed = await store.handle(request("acquire", committedID))
            LocalProxyFixtureRuntime.afterRunning = nil
            expect(
                committed.error == "not_participating" && committed.accessToken == nil && committed.leaseID == nil,
                "off/on after running-state commit still fails final token admission")
            await release(committed, id: committedID)
            try expect(
                try DispatchActivityStore.live.read().leases.allSatisfy { $0.taskId != "proxy-\(run)-\(committedID)" || !$0.occupied },
                "final-check revocation rolls back the exact committed lease")
            _ = await store.handle(request("order_end", committedID, target: ""))
            let freshID = requestID()
            _ = await store.handle(request("order", freshID))
            let fresh = await store.handle(request("acquire", freshID))
            expect(fresh.ok && fresh.accessToken != nil && fresh.leaseID != nil, "new order admits re-enabled Pro20x")
            store.setAccountEnabled(id: pro.id, enabled: false)
            let heartbeat = await store.handle(request("heartbeat", freshID, lease: fresh.leaseID))
            expect(
                heartbeat.ok && fresh.leaseID.flatMap { store.leases[$0]?.isAdmitted } == true,
                "already admitted Pro20x response keeps its heartbeat after removal")
            await release(fresh, id: freshID)
            expect(store.leases.isEmpty && child.isRunning, "owned response releases without stopping the runtime")
            store.setAccountEnabled(id: pro.id, enabled: true)
            store.setAccountLast(id: pro.id, last: false)
            let explicitID = requestID()
            let explicit = await store.handle(request("order", explicitID))
            expect(
                explicit.deferredIDs?.isEmpty == true && store.preferences.lastOverrides?[pro.id] == false,
                "explicit Pro20x Use last cancellation reaches the next host order")
            store.setAccountPriority(id: pro.id, priority: true)
            let priorityID = requestID()
            let priority = await store.handle(request("order", priorityID))
            expect(
                priority.order?.first == pro.id && priority.deferredIDs?.isEmpty == true,
                "Pro20x priority reaches actual next order without forced last")
            store.setAccountLast(id: pro.id, last: true)
            let lastID = requestID()
            let last = await store.handle(request("order", lastID))
            expect(
                last.order?.last == pro.id && last.deferredIDs == [pro.id] && !store.preferences.priorityIDs.contains(pro.id),
                "explicit last remains movable and mutually exclusive with priority")
            let frozen = await store.handle(request("order", explicitID))
            expect(
                frozen.order == explicit.order && frozen.deferredIDs == explicit.deferredIDs,
                "routing edits preserve old metadata while participation revocation stays independent")
            for id in [freshID, explicitID, priorityID, lastID] { _ = await store.handle(request("order_end", id, target: "")) }
            store.process = nil
            store.phase = .stopped
        }
        if selected == nil || selected == "mirrors" {
            var mirrorA = profile("mirror-pro20-A", plan: "pro", email: "mirror@example.invalid", account: "mirror-account")
            mirrorA.proTierMultiplier = 20
            mirrorA.lastSnapshot?.fiveHour = nil
            var mirrorB = profile("mirror-pro20-B", plan: "pro", email: "mirror@example.invalid", account: "mirror-account")
            mirrorB.proTierMultiplier = 20
            mirrorB.lastSnapshot?.fiveHour = nil
            let peer = profile("mirror-peer")
            var central = profile("mirror-central")
            central.isSystemProfile = true
            for candidate in [mirrorA, mirrorB, peer, central] { try writeCredentials(candidate) }
            let usage = UsageStore([mirrorA, mirrorB, peer, central])
            usage.isPreview = false
            let store = LocalProxyQueueStore(usageStore: usage)
            store.setAccountLast(id: mirrorA.id, last: false)
            store.setAccountEnabled(id: mirrorA.id, enabled: false)
            expect(
                store.preferences.knownIDs.isSuperset(of: [mirrorA.id, mirrorB.id])
                    && !store.preferences.enabledIDs.contains(mirrorA.id) && !store.preferences.enabledIDs.contains(mirrorB.id),
                "removing the visible mirror records all current same-key mirrors as known and disabled")
            usage.profiles = [mirrorB, mirrorA, peer, central]
            store.rebuildRows()
            expect(
                store.rows.first(where: { $0.id == mirrorA.id })?.isEnabled == false && !store.rows.contains { $0.id == mirrorB.id },
                "stopped mirror reorder cannot default-enable the cancelled identity")
            let reload = LocalProxyQueueStore(usageStore: usage)
            expect(
                reload.rows.first(where: { $0.id == mirrorA.id })?.isEnabled == false
                    && reload.preferences.knownIDs.isSuperset(of: [mirrorA.id, mirrorB.id]),
                "mirror cancellation survives disk reload with the other representative first")
            expect(
                reload.rows.first(where: { $0.id == mirrorA.id })?.isLast == false
                    && reload.preferences.lastOverrides?[mirrorA.id] == false, "persistent mirror representative preserves explicit Pro20x Use last cancellation")
            let stoppedIndex = usage.profiles.firstIndex(where: { $0.id == mirrorA.id })!
            usage.profiles[stoppedIndex].lastSnapshot?.accountID = nil
            store.rebuildRows()
            expect(
                store.rows.contains { $0.id == mirrorA.id && !$0.isEnabled && !$0.isLast }
                    && !store.rows.contains { $0.id == mirrorB.id }, "stopped nil accountID keeps the persistent representative and its explicit last opt-out")
            usage.profiles[stoppedIndex].lastSnapshot = nil
            let missingSnapshot = LocalProxyQueueStore(usageStore: usage)
            expect(
                missingSnapshot.rows.contains { $0.id == mirrorA.id && !$0.isEnabled && !$0.isLast }
                    && missingSnapshot.preferences.accountRepresentatives == reload.preferences.accountRepresentatives,
                "complete snapshot absence keeps the hashed representative through reload without inferring identity")
            usage.profiles[stoppedIndex] = mirrorA
            store.rebuildRows()
            store.setAccountEnabled(id: mirrorA.id, enabled: true)
            expect(
                store.preferences.enabledIDs.isSuperset(of: [mirrorA.id, mirrorB.id]),
                "explicit mirror re-enable records the same choice for all current mirrors")
            // This is the state after startup excluded a remembered nil-identity
            // row from the verified pool while another healthy member started.
            usage.profiles[stoppedIndex].lastSnapshot?.accountID = nil
            let nilStart = LocalProxyQueueStore(usageStore: usage)
            nilStart.process = child
            nilStart.phase = .running
            nilStart.registeredPool = [peer.id: .init(home: peer.codexHomeURL, account: peer.recordedAccountKey, accountID: peer.lastSnapshot!.accountID!)]
            nilStart.activeIDs = [peer.id]
            expect(
                nilStart.rows.contains { $0.id == mirrorA.id && $0.isEnabled } && nilStart.canToggleAccount(id: mirrorA.id),
                "a startup-skipped enabled nil-identity row remains removable while healthy members run")
            nilStart.setAccountEnabled(id: mirrorA.id, enabled: false)
            nilStart.setAccountEnabled(id: mirrorA.id, enabled: true)
            expect(
                !nilStart.preferences.enabledIDs.contains(mirrorA.id) && !nilStart.preferences.enabledIDs.contains(mirrorB.id)
                    && nilStart.activeIDs == [peer.id], "startup-skipped nil row can be removed but cannot rejoin the verified run")
            nilStart.process = nil
            usage.profiles[stoppedIndex] = mirrorA
            usage.profiles = [mirrorA, mirrorB, peer, central]
            store.rebuildRows()
            store.setAccountEnabled(id: mirrorA.id, enabled: true)
            let run = UUID().uuidString
            let key = "synthetic-mirrors"
            store.process = child
            store.phase = .running
            store.runID = run
            store.controlKey = key
            store.registeredPool = Dictionary(
                uniqueKeysWithValues: [mirrorA, peer].map {
                    (
                        $0.id,
                        LocalProxyQueueStore.PoolBinding(home: $0.codexHomeURL, account: $0.recordedAccountKey, accountID: $0.lastSnapshot!.accountID!)
                    )
                })
            store.activeIDs = [mirrorA.id, peer.id]
            HubConsoleModel.fixtureAvailability = .idle
            func request(_ command: String, _ id: String, lease: String? = nil) -> LocalProxyRequest {
                .init(
                    schemaVersion: 1, runID: run, key: key, command: command, requestID: id,
                    profileID: command == "order_end" ? "" : mirrorA.id, leaseID: lease)
            }
            usage.profiles = [mirrorB, mirrorA, peer, central]
            store.rebuildRows()
            expect(
                store.rows.contains { $0.id == mirrorA.id } && !store.rows.contains { $0.id == mirrorB.id }
                    && store.canToggleAccount(id: mirrorA.id), "running mirror reorder retains the registered representative and live checkbox")
            let pinnedID = requestID()
            let pinned = await store.handle(request("order", pinnedID))
            expect(
                pinned.order?.contains(mirrorA.id) == true && pinned.order?.contains(mirrorB.id) == false,
                "actual running order keeps the registered identity after mirror reorder")
            let nilIndex = usage.profiles.firstIndex(where: { $0.id == mirrorA.id })!
            usage.profiles[nilIndex].lastSnapshot?.accountID = nil
            store.rebuildRows()
            let nilID = requestID()
            let nilOrder = await store.handle(request("order", nilID))
            expect(
                store.rows.contains { $0.id == mirrorA.id } && store.canToggleAccount(id: mirrorA.id)
                    && nilOrder.order?.contains(mirrorA.id) == false && nilOrder.order?.contains(mirrorB.id) == false,
                "running nil accountID leaves the registered representative visible and removable but never admits its mirror")
            usage.profiles[nilIndex].lastSnapshot = nil
            store.rebuildRows()
            store.setAccountEnabled(id: mirrorA.id, enabled: false)
            expect(
                !store.activeIDs.contains(mirrorA.id) && !store.preferences.enabledIDs.contains(mirrorB.id),
                "removal with the entire snapshot missing still synchronizes all known same-identity mirrors")
            usage.profiles[nilIndex] = mirrorA
            store.rebuildRows()
            store.setAccountEnabled(id: mirrorA.id, enabled: true)
            expect(
                store.preferences.accountRepresentatives?[DispatchActivityStore.hash(mirrorA.recordedAccountKey)] == mirrorA.id,
                "nil snapshot recovery keeps the original representative and binding")
            store.setAccountEnabled(id: mirrorA.id, enabled: false)
            expect(
                !store.activeIDs.contains(mirrorA.id) && !store.preferences.enabledIDs.contains(mirrorB.id),
                "removal after reorder disables the registered member and every current mirror")
            store.setAccountEnabled(id: mirrorA.id, enabled: true)
            let rejoinedID = requestID()
            _ = await store.handle(request("order", rejoinedID))
            let rejoined = await store.handle(request("acquire", rejoinedID))
            expect(rejoined.ok && rejoined.accessToken != nil, "re-enabled registered Pro20x mirror admits through the production store")
            if let lease = rejoined.leaseID { _ = await store.handle(request("release", rejoinedID, lease: lease)) }
            let changedIndex = usage.profiles.firstIndex(where: { $0.id == mirrorA.id })!
            usage.profiles[changedIndex].lastSnapshot?.accountID = "changed-mirror-account"
            store.rebuildRows()
            let changedID = requestID()
            let changed = await store.handle(request("order", changedID))
            expect(
                changed.order?.contains(mirrorA.id) == false && changed.order?.contains(mirrorB.id) == false,
                "identity change cannot silently substitute an unregistered mirror")
            store.setAccountEnabled(id: mirrorA.id, enabled: false)
            store.setAccountEnabled(id: mirrorA.id, enabled: true)
            expect(!store.activeIDs.contains(mirrorA.id), "changed identity cannot be re-enabled into the running pool")
            usage.profiles[changedIndex] = mirrorA
            store.rebuildRows()
            store.setAccountEnabled(id: mirrorA.id, enabled: true)
            // Change the peripheral profile's home URL, retaining the same id
            // and official identity; the Store binding check stays production code.
            usage.profiles[changedIndex].fixtureHomeURL = root.appendingPathComponent("changed-profile-home")
            let homeID = requestID()
            let home = await store.handle(request("order", homeID))
            expect(
                home.order?.contains(mirrorA.id) == false && !store.isRegisteredBindingCurrent(mirrorA.id),
                "a changed profile home stays outside the registered order")
            usage.profiles[changedIndex] = mirrorA
            let before = try Data(contentsOf: file)
            let beforeIDs = store.activeIDs
            let beforeKnown = store.preferences.knownIDs
            let beforeEnabled = store.preferences.enabledIDs
            let beforeRepresentatives = store.preferences.accountRepresentatives
            let beforeRevocations = store.memberRevocations
            let beforeRegistry = try? Data(contentsOf: registry)
            let blocked = URL(fileURLWithPath: file.path + ".blocked")
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
            LocalProxyFixtureRuntime.failPreferenceRename = true
            store.setAccountEnabled(id: mirrorA.id, enabled: false)
            LocalProxyFixtureRuntime.failPreferenceRename = false
            store.flushDisplayRows()
            try expect(
                try Data(contentsOf: file) == before && store.activeIDs == beforeIDs
                    && store.preferences.knownIDs == beforeKnown && store.preferences.enabledIDs == beforeEnabled
                    && store.preferences.accountRepresentatives == beforeRepresentatives && store.memberRevocations == beforeRevocations
                    && store.rows.first(where: { $0.id == mirrorA.id })?.isEnabled == true
                    && (try? Data(contentsOf: registry)) == beforeRegistry,
                "failed atomic save rolls back mirror choices, runtime membership, display and disk")
            store.process = nil
            store.phase = .stopped
            // Legacy preferences have no representative map. A known configured
            // home must win over a new first mirror during the first migration.
            var legacy = LocalProxyPreferences()
            legacy.knownIDs = [mirrorA.id, peer.id]
            legacy.enabledIDs = [mirrorA.id, peer.id]
            legacy.lastOverrides = [mirrorA.id: false]
            legacy.priorityIDs = [mirrorA.id]
            legacy.order = [mirrorA.id, peer.id]
            try JSONEncoder().encode(legacy).write(to: file, options: .atomic)
            let migrated = LocalProxyQueueStore(usageStore: usage)
            expect(
                migrated.rows.first?.id == mirrorA.id && migrated.rows.first?.isPriority == true && migrated.rows.first?.isLast == false,
                "old schema without mapping prefers the known configured Pro20x home over the first mirror")
            let identityHash = DispatchActivityStore.hash(mirrorA.recordedAccountKey)
            expect(
                migrated.preferences.accountRepresentatives?[identityHash] == mirrorA.id && migrated.preferences.validAccountRepresentatives,
                "legacy representative migrates using only a valid identity hash")
            migrated.setAccountEnabled(id: mirrorA.id, enabled: false)
            // Later scenarios replay this metadata snapshot after newer saves.
            // Model a legacy metadata-only file, not a stale deleted Keychain revision.
            var metadataSnapshot = try JSONDecoder().decode(LocalProxyPreferences.self, from: Data(contentsOf: file))
            metadataSnapshot.secretsReference = nil
            let persisted = try JSONEncoder().encode(metadataSnapshot)
            expect(
                !String(decoding: persisted, as: UTF8.self).contains("mirror@example.invalid")
                    && LocalProxyQueueStore(usageStore: usage).rows.first?.id == mirrorA.id,
                "representative persists without adding plaintext account data")
            var invalid = LocalProxyPreferences()
            invalid.accountRepresentatives = ["email@example.invalid": mirrorA.id]
            expect(!invalid.validAccountRepresentatives, "malformed representative identity hashes fail validation")
            // The old representative has actually disappeared. A new same-key
            // home inherits only this identity's committed opt-out and routing.
            var newcomer = profile("mirror-new-home", plan: "pro", email: "mirror@example.invalid", account: "mirror-account")
            newcomer.proTierMultiplier = 20
            newcomer.lastSnapshot?.fiveHour = nil
            usage.profiles = [newcomer, peer, central]
            let fallback = LocalProxyQueueStore(usageStore: usage)
            expect(
                fallback.rows.contains { $0.id == newcomer.id && !$0.isEnabled && !$0.isLast && $0.isPriority }
                    && fallback.preferences.knownIDs.contains(newcomer.id),
                "deleted representative fallback preserves same-identity removal and explicit routing instead of first-seed enable")
            fallback.setAccountEnabled(id: newcomer.id, enabled: false)
            expect(
                LocalProxyQueueStore(usageStore: usage).rows.contains { $0.id == newcomer.id && !$0.isEnabled && !$0.isLast },
                "deleted representative fallback persists through the next existing atomic save")
            var manualOrder = try JSONDecoder().decode(LocalProxyPreferences.self, from: persisted)
            manualOrder.priorityIDs.remove(mirrorA.id)
            manualOrder.order = [mirrorA.id, peer.id]
            try JSONEncoder().encode(manualOrder).write(to: file, options: .atomic)
            let manualFallback = LocalProxyQueueStore(usageStore: usage)
            expect(
                manualFallback.preferences.order == [newcomer.id, peer.id] && manualFallback.rows.map(\.id) == [newcomer.id, peer.id],
                "same-identity representative migration preserves the old manual slot and unrelated account order without priority")
            var changedIdentity = mirrorA
            changedIdentity.lastSnapshot?.email = "different-identity@example.invalid"
            changedIdentity.lastSnapshot?.accountID = "different-identity-account"
            var stalePointer = try JSONDecoder().decode(LocalProxyPreferences.self, from: persisted)
            let newIdentityPolicy = LocalProxyAccountPolicy(fiveHourUsedLimit: 60, allowsCredits: false)
            let originalMirrorPolicy = LocalProxyAccountPolicy(fiveHourUsedLimit: 80, allowsCredits: true, creditPrimaryFloor: 4000, creditSecondaryFloor: 3000)
            stalePointer.accountPolicies = [mirrorA.id: newIdentityPolicy, newcomer.id: originalMirrorPolicy]
            stalePointer.lastOverrides?[newcomer.id] = true
            stalePointer.enabledIDs.insert(newcomer.id)
            try JSONEncoder().encode(stalePointer).write(to: file, options: .atomic)
            usage.profiles = [changedIdentity, newcomer, peer, central]
            let guardedMigration = LocalProxyQueueStore(usageStore: usage)
            expect(
                guardedMigration.preferences.knownIDs.contains(newcomer.id) && !guardedMigration.preferences.enabledIDs.contains(newcomer.id)
                    && guardedMigration.preferences.policy(for: newcomer.id) == originalMirrorPolicy
                    && guardedMigration.preferences.lastOverrides?[newcomer.id] == true
                    && !guardedMigration.preferences.priorityIDs.contains(newcomer.id),
                "historical hash pointer cannot copy a changed identity's enabled, spending or routing rules to its old mirror")
            try Data(persisted).write(to: file, options: .atomic)
            usage.profiles = [mirrorA, mirrorB, peer, central]
            let vanished = LocalProxyQueueStore(usageStore: usage)
            vanished.process = child
            vanished.phase = .running
            vanished.runID = UUID().uuidString
            vanished.controlKey = key
            vanished.registeredPool = [
                mirrorA.id: .init(
                    home: mirrorA.codexHomeURL, account: mirrorA.recordedAccountKey,
                    accountID: mirrorA.lastSnapshot!.accountID!)
            ]
            vanished.activeIDs = []
            usage.profiles = [newcomer, peer, central]
            vanished.rebuildRows()
            expect(
                vanished.preferences.accountRepresentatives?[identityHash] == mirrorA.id && !vanished.canToggleAccount(id: newcomer.id)
                    && !vanished.preferences.enabledIDs.contains(newcomer.id),
                "deleting a run representative cannot substitute or default-enable a new unregistered home")
            vanished.process = nil
        }
        if selected == nil || selected == "display-order" {
            let first = profile("display-first")
            let second = profile("display-second")
            let third = profile("display-third")
            let displayUsage = UsageStore([first, second, third])
            displayUsage.isPreview = false
            var choices = LocalProxyPreferences()
            choices.knownIDs = [first.id, second.id, third.id]
            choices.enabledIDs = choices.knownIDs
            choices.order = [third.id, first.id, second.id]
            choices.priorityIDs = [second.id]
            try JSONEncoder().encode(choices).write(to: file, options: .atomic)
            let displayed = LocalProxyQueueStore(usageStore: displayUsage)
            displayed.flushDisplayRows()
            expect(
                displayed.rows.map(\.id) == [second.id, third.id, first.id]
                    && displayed.displayRows.map(\.id) == [third.id, first.id, second.id],
                "saved manual display order is separate from priority routing and initial account order")
            expect(
                !displayed.canMoveAccount(id: third.id, by: -1) && !displayed.canMoveAccount(id: second.id, by: 1)
                    && displayed.canMoveAccount(id: first.id, by: -1),
                "arrow availability follows the visible first, middle and last rows")
            displayed.moveAccount(id: first.id, by: -1)
            expect(
                displayed.displayRows.map(\.id) == [first.id, third.id, second.id]
                    && displayed.preferences.order == [first.id, third.id, second.id],
                "arrow swaps its visible neighbor and publishes immediately")
            displayed.rebuildRows()
            displayed.flushDisplayRows()
            let afterMove = LocalProxyQueueStore(usageStore: displayUsage)
            expect(
                displayed.displayRows.map(\.id) == [first.id, third.id, second.id]
                    && afterMove.displayRows.map(\.id) == [first.id, third.id, second.id],
                "manual display move survives rebuild and preference reload")
            displayed.setAccountPriority(id: second.id, priority: false)
            displayed.setAccountLast(id: first.id, last: true)
            displayed.setAccountEnabled(id: third.id, enabled: false)
            displayed.flushDisplayRows()
            expect(
                displayed.displayRows.map(\.id) == [first.id, third.id, second.id],
                "participation, priority and use-last edits keep the saved display order stable")
            displayed.moveAccount(id: third.id, by: -1)
            expect(
                displayed.displayRows.map(\.id) == [third.id, first.id, second.id]
                    && displayed.rows.first(where: { $0.id == third.id })?.isLast == true,
                "cross-group arrow adopts the displayed neighbor choice and moves one visible place")
            displayed.setAccountLast(id: first.id, last: false)
            displayed.setAccountLast(id: third.id, last: false)
            displayed.flushDisplayRows()
            expect(
                displayed.rows.map(\.id) == displayed.displayRows.map(\.id),
                "routing uses the same saved manual order within equal groups")
            let previous = displayed.displayRows
            let bytes = try Data(contentsOf: file)
            let blockedMove = URL(fileURLWithPath: file.path + ".blocked")
            if !FileManager.default.fileExists(atPath: blockedMove.path) {
                try FileManager.default.createDirectory(at: blockedMove, withIntermediateDirectories: false)
            }
            LocalProxyFixtureRuntime.failPreferenceRename = true
            displayed.moveAccount(id: first.id, by: 1)
            LocalProxyFixtureRuntime.failPreferenceRename = false
            try expect(
                displayed.preferencesFailure == .save && displayed.displayRows == previous
                    && Data(contentsOf: file) == bytes,
                "failed manual move rolls back both visible order and saved bytes")
        }
        print("PARTICIPATION_RESULT checks=\(checks) failures=\(failures.count)")
        guard failures.isEmpty else { throw ParticipationFixtureFailure(checks: failures) }
        print("PASS: \(checks) production participation checks; synthetic Pro20x, mirrors, order and admission only")
    }
}
