import Foundation

@MainActor
func runAutomaticDefaultWiringTests() async {
    func settle() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }
    func profile(_ id: String, type: String? = "chatgpt", successful: Bool? = true, failed: Bool = false) -> CodexProfile {
        CodexProfile(id: id, lastSnapshot: .init(accountID: "synthetic-" + id, quotaReadSucceeded: successful, accountType: type), lastQuotaReadFailureAt: failed ? Date() : nil)
    }
    let fixture = AutomaticRunnerFixture()
    fixture.hasStarted = false
    fixture.profileStore.profiles = [
        profile("ready"), profile("unread", successful: nil), profile("failed", failed: true), profile("api", type: "apiKey"), profile("unknown-type", type: nil),
    ]
    fixture.profiles = fixture.profileStore.profiles
    var saved: [CodexResetCreditAutoPreferences] = []
    var insideSave = false
    var recursiveSave = false
    fixture.configureResetCreditAuto(.init()) { preferences in
        if insideSave { recursiveSave = true }
        insideSave = true
        saved.append(preferences)
        fixture.configureResetCreditAuto(preferences)
        insideSave = false
        return true
    }
    ResetCreditAutoTests.expect(saved.isEmpty && fixture.resetCreditAutoPreferences.authorizedAccounts.isEmpty, "default registration defers past the Published setter")
    await settle()
    ResetCreditAutoTests.expect(saved.count == 1 && !recursiveSave, "saved default config reentry settles without recursive publications")
    ResetCreditAutoTests.expect(
        fixture.resetCreditAutoPreferences.authorizedAccounts == ["ready": DispatchActivityStore.hash("synthetic-ready")],
        "production registration requires successful ChatGPT identity and quota evidence")
    ResetCreditAutoTests.expect(fixture.resetCreditAutoController.attempted.isEmpty, "registration does not bypass stopped runtime or trigger a consume")
    fixture.profileStore.profiles[1] = profile("unread")
    fixture.profiles = fixture.profileStore.profiles
    await settle()
    ResetCreditAutoTests.expect(
        fixture.resetCreditAutoPreferences.permits(profileID: "unread", accountID: "synthetic-unread") && saved.count == 2,
        "profile observer registers a newly verified account once")
    fixture.profileStore.profiles[0].lastSnapshot?.accountID = "synthetic-changed"
    fixture.profiles = fixture.profileStore.profiles
    await settle()
    ResetCreditAutoTests.expect(
        !fixture.resetCreditAutoPreferences.permits(profileID: "ready", accountID: "synthetic-changed") && saved.count == 2,
        "profile identity change does not replace the saved binding")

    let failedSave = AutomaticRunnerFixture()
    failedSave.hasStarted = false
    failedSave.profileStore.profiles = [profile("ready")]
    failedSave.profiles = failedSave.profileStore.profiles
    var failedSaves = 0
    failedSave.configureResetCreditAuto(.init()) { _ in
        failedSaves += 1
        return false
    }
    await settle()
    ResetCreditAutoTests.expect(failedSaves == 1 && failedSave.resetCreditAutoPreferences.authorizedAccounts.isEmpty, "failed persistence never grants locally or loops")

    for action in ["off", "all-off", "clear-old-identity"] {
        let queued = AutomaticRunnerFixture()
        queued.hasStarted = false
        queued.profileStore.profiles = [profile("ready")]
        queued.profiles = queued.profileStore.profiles
        var before = CodexResetCreditAutoPreferences()
        if action == "clear-old-identity" { before.setEnabled(true, profileID: "ready", accountID: "synthetic-old") }
        var queuedSaves = 0
        queued.configureResetCreditAuto(before) { preferences in
            queuedSaves += 1
            queued.configureResetCreditAuto(preferences)
            return true
        }
        var changed = before
        if action == "all-off" { changed.disableAll(profileIDs: ["ready"]) } else { changed.setEnabled(false, profileID: "ready") }
        queued.configureResetCreditAuto(changed)
        await settle()
        ResetCreditAutoTests.expect(
            queuedSaves == 0 && queued.resetCreditAutoPreferences.disabledProfileIDs.contains("ready")
                && !queued.resetCreditAutoPreferences.permits(profileID: "ready", accountID: "synthetic-ready"),
            "queued registration respects latest \(action) without saving an older grant")
    }
    let changedIdentity = AutomaticRunnerFixture()
    changedIdentity.hasStarted = false
    changedIdentity.profileStore.profiles = [profile("ready")]
    changedIdentity.profiles = changedIdentity.profileStore.profiles
    var identitySaves = 0
    changedIdentity.configureResetCreditAuto(.init()) { preferences in
        identitySaves += 1
        changedIdentity.configureResetCreditAuto(preferences)
        return true
    }
    changedIdentity.profileStore.profiles[0].lastSnapshot?.accountID = "synthetic-latest"
    changedIdentity.profiles = changedIdentity.profileStore.profiles
    await settle()
    ResetCreditAutoTests.expect(
        identitySaves == 1 && changedIdentity.resetCreditAutoPreferences.permits(profileID: "ready", accountID: "synthetic-latest")
            && !changedIdentity.resetCreditAutoPreferences.permits(profileID: "ready", accountID: "synthetic-ready"),
        "queued first registration uses the latest verified identity rather than a captured old snapshot")
    let changedList = AutomaticRunnerFixture()
    changedList.hasStarted = false
    changedList.profileStore.profiles = [profile("ready")]
    changedList.profiles = changedList.profileStore.profiles
    var listSaves = 0
    changedList.configureResetCreditAuto(.init()) { _ in
        listSaves += 1
        return false
    }
    changedList.profiles = []
    await settle()
    ResetCreditAutoTests.expect(
        listSaves == 0 && changedList.resetCreditAutoPreferences.authorizedAccounts.isEmpty,
        "queued registration rejects a now-incomplete published profile list")

    let migration = AutomaticRunnerFixture()
    migration.hasStarted = false
    migration.profileStore.profiles = [profile("legacy-off")]
    migration.profiles = migration.profileStore.profiles
    migration.profileStore.hasReliableProfileList = false
    let legacy = CodexResetCreditAutoPreferences.load(Data(#"{"authorizedAccounts":{},"leadMinutes":30}"#.utf8))
    var migrationSaves = 0
    migration.configureResetCreditAuto(legacy) { preferences in
        migrationSaves += 1
        migration.configureResetCreditAuto(preferences)
        return true
    }
    await settle()
    ResetCreditAutoTests.expect(migrationSaves == 0 && migration.resetCreditAutoPreferences.legacyMigrationPending, "damaged profile-store fallback cannot complete migration")
    migration.profileStore.hasReliableProfileList = true
    migration.profiles = []
    await settle()
    ResetCreditAutoTests.expect(migrationSaves == 0, "partial published profile list cannot complete migration")
    migration.profiles = migration.profileStore.profiles
    await settle()
    ResetCreditAutoTests.expect(
        migrationSaves == 1 && migration.resetCreditAutoPreferences.disabledProfileIDs == ["legacy-off"], "complete profile list migrates legacy off exactly once")
    migration.profileStore.profiles.append(profile("later"))
    migration.profiles = migration.profileStore.profiles
    await settle()
    ResetCreditAutoTests.expect(
        migrationSaves == 2 && migration.resetCreditAutoPreferences.permits(profileID: "later", accountID: "synthetic-later"),
        "new profile after migration defaults on while legacy off remains unchanged")
    let preview = AutomaticRunnerFixture()
    preview.isPreview = true
    preview.profileStore.profiles = [profile("ready")]
    preview.profiles = preview.profileStore.profiles
    var previewSaves = 0
    preview.configureResetCreditAuto(.init()) { _ in
        previewSaves += 1
        return true
    }
    await settle()
    ResetCreditAutoTests.expect(previewSaves == 0 && preview.resetCreditAutoPreferences.authorizedAccounts.isEmpty, "preview never persists or grants default authorizations")
}

@MainActor
func runAutomaticWiringTests() async {
    func configured() -> AutomaticRunnerFixture {
        let system = CodexProfile(id: "system", lastSnapshot: .init(accountID: "desktop"), isSystemProfile: true)
        let first = CodexProfile(id: "first", lastSnapshot: .init(accountID: "one", resetCreditExpiries: [Date().addingTimeInterval(600)]))
        let second = CodexProfile(id: "second", lastSnapshot: .init(accountID: "two", resetCreditExpiries: [Date().addingTimeInterval(600)]))
        let value = AutomaticRunnerFixture()
        value.profiles = [system, first, second]
        value.aliases = ["first": "first-alias", "second": "second-alias"]
        value.resetCreditAutoPreferences.authorizedAccounts = ["first": DispatchActivityStore.hash("one"), "second": DispatchActivityStore.hash("two")]
        return value
    }
    let startup = configured()
    startup.resetCreditAutoDesktopVerified = false
    startup.checkResetCreditAuto()
    await startup.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(startup.resetCreditAutoController.attempted.isEmpty, "runner startup requires verified desktop identity")
    let refreshing = configured()
    refreshing.identityRefreshCancellation = UUID()
    refreshing.checkResetCreditAuto()
    await refreshing.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(refreshing.resetCreditAutoController.attempted.isEmpty, "runner identity refresh in flight blocks checks")
    let missingSystem = configured()
    missingSystem.profiles.removeAll { $0.isSystemProfile }
    missingSystem.checkResetCreditAuto()
    await missingSystem.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(missingSystem.resetCreditAutoController.attempted.isEmpty, "runner missing system identity blocks checks")
    let mirror = configured()
    mirror.profiles[1].lastSnapshot?.accountID = "desktop"
    mirror.resetCreditAutoPreferences.authorizedAccounts["first"] = DispatchActivityStore.hash("desktop")
    mirror.checkResetCreditAuto()
    await mirror.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(mirror.resetCreditAutoController.attempted == ["first", "second"], "runner includes explicitly authorized managed mirror of desktop account")
    func desktopOnly() -> AutomaticRunnerFixture {
        let value = configured()
        value.profiles[0].lastSnapshot?.resetCreditExpiries = [Date().addingTimeInterval(600)]
        value.profiles[1].lastSnapshot?.accountID = "desktop"
        value.resetCreditAutoPreferences.authorizedAccounts = ["system": DispatchActivityStore.hash("desktop")]
        return value
    }
    let desktop = desktopOnly()
    desktop.checkResetCreditAuto()
    await desktop.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(desktop.resetCreditAutoController.attempted == ["first"], "desktop-only consent executes independent mirror without enabling mirror switch")
    ResetCreditAutoTests.expect(desktop.resetCreditAutoPreferences.authorizedAccounts["first"] == nil, "desktop execution preserves independent mirror consent")
    let both = desktopOnly()
    both.resetCreditAutoPreferences.authorizedAccounts["first"] = DispatchActivityStore.hash("desktop")
    both.checkResetCreditAuto()
    await both.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(both.resetCreditAutoController.attempted == ["first"], "desktop and mirror consent share one card pool attempt")
    let noMirror = desktopOnly()
    noMirror.profiles.removeAll { !$0.isSystemProfile }
    noMirror.checkResetCreditAuto()
    await noMirror.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(
        noMirror.resetCreditAutoController.attempted.isEmpty && noMirror.resetCreditAutoStatus != nil, "desktop without independent mirror pauses with visible reason")
    let noDesktopAlias = desktopOnly()
    noDesktopAlias.aliases = [:]
    noDesktopAlias.checkResetCreditAuto()
    await noDesktopAlias.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(
        noDesktopAlias.resetCreditAutoController.attempted.isEmpty && noDesktopAlias.resetCreditAutoStatus != nil, "desktop mirror without Hub mapping sends zero RPCs")
    let sameHome = desktopOnly()
    sameHome.profiles[1].homeOverride = sameHome.profiles[0].codexHomeURL
    sameHome.checkResetCreditAuto()
    await sameHome.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(sameHome.resetCreditAutoController.attempted.isEmpty, "managed label cannot bypass desktop credential-home isolation")
    let noConsent = desktopOnly()
    noConsent.resetCreditAutoPreferences.authorizedAccounts = [:]
    noConsent.checkResetCreditAuto()
    await noConsent.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(noConsent.resetCreditAutoController.attempted.isEmpty, "desktop auto redemption still requires a persisted identity grant")
    for state: TaskRuntimeState in [.running, .waitingInput, .recorded, .disconnected] {
        let active = desktopOnly()
        active.codexLiveTasks = .init(
            connectionMode: .sharedDaemon, records: ["task": .init(threadID: "task", name: nil, state: state, updatedAt: Date(), turnID: nil, connectionMode: .sharedDaemon)],
            refreshedAt: Date())
        active.checkResetCreditAuto()
        await active.resetCreditAutoTask?.value
        ResetCreditAutoTests.expect(
            active.resetCreditAutoController.attempted.isEmpty && active.resetCreditAutoStatus != nil, "desktop \(state.rawValue) task state prevents automatic review")
    }
    let staleTask = desktopOnly()
    staleTask.codexLiveTasks = .init(connectionMode: .sharedDaemon, records: [:], refreshedAt: Date().addingTimeInterval(-60))
    staleTask.checkResetCreditAuto()
    await staleTask.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(staleTask.resetCreditAutoController.attempted.isEmpty, "stale desktop task evidence cannot authorize redemption")
    let disconnectedTask = desktopOnly()
    disconnectedTask.codexLiveTasks = .disconnected
    disconnectedTask.checkResetCreditAuto()
    await disconnectedTask.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(disconnectedTask.resetCreditAutoController.attempted.isEmpty, "disconnected desktop task evidence pauses redemption")
    let view = FixtureAutoEligibilityView(profiles: desktopOnly().profiles)
    ResetCreditAutoTests.expect(
        view.blockedReason(view.profiles[0]) == nil && view.blockedReason(view.profiles[1]) == nil,
        "production eligibility enables desktop and mirror rows with verified independent credentials")
    let unavailableView = FixtureAutoEligibilityView(profiles: noMirror.profiles)
    ResetCreditAutoTests.expect(unavailableView.blockedReason(unavailableView.profiles[0]) != nil, "production eligibility explains absent independent credentials")
    func inFlight() -> AutomaticRunnerFixture {
        let value = desktopOnly()
        value.profileStore.profiles = value.profiles
        value.resetCreditAutoAdmission = .init()
        value.resetCreditAutoIdentity = (value.profiles[1].id, "desktop", value.profiles[1].codexHomeURL)
        value.resetCreditAutoOriginIdentity = (value.profiles[0].id, "desktop", value.profiles[0].codexHomeURL)
        value.resetCreditAutoDesktopAccountID = "desktop"
        return value
    }
    let unchanged = inFlight()
    unchanged.syncAutomaticIdentity()
    ResetCreditAutoTests.expect(
        unchanged.resetCreditAutoAdmission?.isCancelled == false && unchanged.resetCreditAutoDesktopVerified, "unchanged desktop identity preserves independent mirror admission")
    let activeDuringRequest = inFlight()
    activeDuringRequest.codexLiveTasks = .disconnected
    ResetCreditAutoTests.expect(activeDuringRequest.resetCreditAutoAdmission?.isCancelled == true, "production task observer revokes an in-flight desktop admission")
    let identityChanges: [(String, (AutomaticRunnerFixture) -> Void)] = [
        ("desktop identity", { $0.profileStore.profiles[0].lastSnapshot?.accountID = "different" }),
        ("desktop quota failure", { $0.profileStore.profiles[0].lastQuotaReadFailureAt = Date() }),
        ("executor removal", { $0.profileStore.profiles.removeAll { $0.id == "first" } }),
        ("executor identity", { $0.profileStore.profiles[1].lastSnapshot?.accountID = "different" }),
        ("executor home", { $0.profileStore.profiles[1].homeOverride = URL(fileURLWithPath: "/synthetic-other-home") }),
        ("executor global home", { $0.profileStore.profiles[1].homeOverride = $0.profiles[0].codexHomeURL }),
        ("executor quota failure", { $0.profileStore.profiles[1].lastQuotaReadFailureAt = Date() }),
        ("origin removal", { $0.profileStore.profiles.removeAll { $0.isSystemProfile } }),
        ("origin home", { $0.profileStore.profiles[0].homeOverride = URL(fileURLWithPath: "/synthetic-origin-home") }),
        ("origin consent", { $0.resetCreditAutoPreferences.authorizedAccounts = [:] }),
    ]
    for (label, mutate) in identityChanges {
        let changed = inFlight()
        mutate(changed)
        changed.syncAutomaticIdentity()
        ResetCreditAutoTests.expect(changed.resetCreditAutoAdmission?.isCancelled == true, "production identity invalidation revokes \(label)")
    }
    let busy = configured()
    busy.resetCreditAutoController.busyIDs = ["first"]
    busy.checkResetCreditAuto()
    await busy.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(
        busy.resetCreditAutoController.attempted == ["first", "second"] && busy.resetCreditAutoController.consumed == ["second"], "first busy account cannot starve next account")
    let missingAlias = configured()
    missingAlias.aliases["first"] = nil
    missingAlias.checkResetCreditAuto()
    await missingAlias.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(missingAlias.resetCreditAutoController.attempted == ["second"], "first account without alias cannot starve next account")
    let duplicateAlias = configured()
    duplicateAlias.aliases["first"] = nil
    duplicateAlias.profiles[2].lastSnapshot?.accountID = "one"
    duplicateAlias.resetCreditAutoPreferences.authorizedAccounts["second"] = DispatchActivityStore.hash("one")
    duplicateAlias.checkResetCreditAuto()
    await duplicateAlias.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(duplicateAlias.resetCreditAutoController.attempted == ["second"], "missing alias cannot consume dedup identity before valid mirror candidate")
    let revocation = configured()
    revocation.resetCreditAutoController.onAttempt = { revocation.identityRefreshCancellation = UUID() }
    revocation.checkResetCreditAuto()
    await revocation.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(revocation.resetCreditAutoController.attempted == ["first"], "runner rechecks identity refresh before each candidate")
}

@MainActor
func runReaderAdmissionChecks() {
    let cancelled = CodexResetCreditAutoAdmission()
    cancelled.cancel()
    let first = ReaderSendFixture()
    first.send(admission: cancelled)
    ResetCreditAutoTests.expect(first.writes == 0 && !first.consumeMayHaveBeenSent && first.failure == .requestNotSent, "actual reader pre-cancel sends zero consume writes")
    let revokedBeforeWrite = CodexResetCreditAutoAdmission()
    let second = ReaderSendFixture()
    second.send(admission: revokedBeforeWrite) { revokedBeforeWrite.cancel() }
    ResetCreditAutoTests.expect(
        second.writes == 0 && !second.consumeMayHaveBeenSent && second.failure == .requestNotSent, "actual reader atomic admission blocks cancellation after precheck")
    let ready = ReaderSendFixture()
    ready.send(admission: .init())
    ResetCreditAutoTests.expect(ready.writes == 1 && ready.consumeMayHaveBeenSent && ready.failure == nil, "actual reader send block admits exactly one write")
    let partial = ReaderSendFixture()
    partial.writeSucceeds = false
    partial.send(admission: .init())
    ResetCreditAutoTests.expect(partial.writes == 1 && partial.consumeMayHaveBeenSent && partial.failure == .outcomeUnknown, "actual reader partial write keeps outcome unknown")
}
