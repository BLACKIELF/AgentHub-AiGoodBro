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
    ResetCreditAutoTests.expect(mirror.resetCreditAutoController.attempted == ["second"], "runner excludes managed mirror of desktop account")
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
