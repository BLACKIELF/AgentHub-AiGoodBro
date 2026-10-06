import Foundation

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
    ResetCreditAutoTests.expect(noMirror.resetCreditAutoController.attempted.isEmpty && noMirror.resetCreditAutoStatus != nil, "desktop without independent mirror pauses with visible reason")
    let noDesktopAlias = desktopOnly()
    noDesktopAlias.aliases = [:]
    noDesktopAlias.checkResetCreditAuto()
    await noDesktopAlias.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(noDesktopAlias.resetCreditAutoController.attempted.isEmpty && noDesktopAlias.resetCreditAutoStatus != nil, "desktop mirror without Hub mapping sends zero RPCs")
    let sameHome = desktopOnly()
    sameHome.profiles[1].homeOverride = sameHome.profiles[0].codexHomeURL
    sameHome.checkResetCreditAuto()
    await sameHome.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(sameHome.resetCreditAutoController.attempted.isEmpty, "managed label cannot bypass desktop credential-home isolation")
    let noConsent = desktopOnly()
    noConsent.resetCreditAutoPreferences.authorizedAccounts = [:]
    noConsent.checkResetCreditAuto()
    await noConsent.resetCreditAutoTask?.value
    ResetCreditAutoTests.expect(noConsent.resetCreditAutoController.attempted.isEmpty, "desktop auto redemption remains opt-in")
    for state: TaskRuntimeState in [.running, .waitingInput, .recorded, .disconnected] {
        let active = desktopOnly()
        active.codexLiveTasks = .init(connectionMode: .sharedDaemon, records: ["task": .init(threadID: "task", name: nil, state: state, updatedAt: Date(), turnID: nil, connectionMode: .sharedDaemon)], refreshedAt: Date())
        active.checkResetCreditAuto()
        await active.resetCreditAutoTask?.value
        ResetCreditAutoTests.expect(active.resetCreditAutoController.attempted.isEmpty && active.resetCreditAutoStatus != nil, "desktop \(state.rawValue) task state prevents automatic review")
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
    ResetCreditAutoTests.expect(view.blockedReason(view.profiles[0]) == nil && view.blockedReason(view.profiles[1]) == nil, "production eligibility enables desktop and mirror rows with verified independent credentials")
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
    ResetCreditAutoTests.expect(unchanged.resetCreditAutoAdmission?.isCancelled == false && unchanged.resetCreditAutoDesktopVerified, "unchanged desktop identity preserves independent mirror admission")
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
        ("origin consent", { $0.resetCreditAutoPreferences.authorizedAccounts = [:] })
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
