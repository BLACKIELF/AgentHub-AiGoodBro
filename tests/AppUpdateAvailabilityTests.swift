import Foundation

func runAvailabilityTests() {
    final class ControlledChecker: AppUpdateChecking {
        var completions: [(AppUpdateResult) -> Void] = []
        func check(currentVersion: String, includePrereleases: Bool, force: Bool, completion: @escaping (AppUpdateResult) -> Void) {
            completions.append(completion)
        }
    }
    let defaults = UserDefaults(suiteName: "AiGoodBro.UpdateFixture.\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    let checker = ControlledChecker()
    let store = AppUpdateStore(settings: settings, checker: checker)
    let metadata = release(digest: "sha256:" + digestHex(FixtureProtocol.package))
    let available = AppUpdateResult(status: .updateAvailable, checkedAt: Date(), currentVersion: "9.6.79", latestRelease: metadata.0, preferredAsset: metadata.1, errorMessage: nil)
    var shown = 0
    AppUpdateStore.presentUpdateDetails = { source in
        require(source === store, "update popup used wrong store")
        shown += 1
    }
    defer { AppUpdateStore.presentUpdateDetails = nil }
    func completeLast() {
        checker.completions.last!(available)
        settle { !store.isChecking }
    }
    store.startAutomaticCheck()
    completeLast()
    require(shown == 1, "first automatic discovery did not show update details")
    store.startAutomaticCheck()
    completeLast()
    require(shown == 1, "automatic discovery repeatedly interrupted user")
    store.checkNow()
    completeLast()
    require(shown == 2, "manual update check could not reopen details")
    store.skipCurrentAvailableVersion()
    store.startAutomaticCheck()
    completeLast()
    require(shown == 2 && store.result.status == .upToDate, "skipped version still prompted automatically")
    store.checkNow()
    completeLast()
    require(shown == 3, "manual check could not review skipped update")
    settings.skippedUpdateVersion = nil
    let aboutChecker = ControlledChecker()
    let aboutStore = AppUpdateStore(settings: settings, checker: aboutChecker)
    var aboutShown = 0
    aboutStore.onUpdateAvailable = { _ in aboutShown += 1 }
    aboutStore.startAutomaticCheck()
    aboutChecker.completions.last!(available)
    settle { !aboutStore.isChecking }
    require(aboutShown == 0, "second About store interrupted user for already announced automatic update")
    aboutStore.checkNow()
    aboutChecker.completions.last!(available)
    settle { !aboutStore.isChecking }
    require(aboutShown == 1, "second About store could not manually review update")
    store.openPreferredUpdateURL()
    require(shown == 4, "existing update entry did not open common details")
    store.startAutomaticCheck()
    settings.automaticUpdateChecksEnabled = false
    settle { store.result.status == .disabled }
    completeLast()
    require(shown == 4 && store.result.status == .disabled, "late automatic reply ignored disabled preference")
    print("update availability fixtures passed")
}
