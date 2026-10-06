import AppKit
import Combine
import Foundation

final class AppUpdateStore: ObservableObject {
    @Published private(set) var result: AppUpdateResult = .idle()
    @Published private(set) var isChecking = false

    /// The app supplies one native presenter so About and Settings use the same window.
    static var presentUpdateDetails: ((AppUpdateStore) -> Void)?
    var onUpdateAvailable: ((AppUpdateStore) -> Void)?

    private let settings: AppSettings
    private let checker: any AppUpdateChecking
    private var activeCheckID: UUID?
    private var activeCheckIsAutomatic = false
    private var cancellables = Set<AnyCancellable>()
    private static var announcedAutomaticUpdates = Set<String>()

    init(
        settings: AppSettings,
        checker: any AppUpdateChecking = GitHubReleaseUpdateChecker()
    ) {
        self.settings = settings
        self.checker = checker
        observeSettings()
    }

    func startAutomaticCheck() {
        guard settings.automaticUpdateChecksEnabled else {
            result = disabledResult()
            return
        }
        check(force: false)
    }

    func checkNow() {
        check(force: true)
    }

    func openPreferredUpdateURL() {
        showUpdateDetails()
    }

    func showUpdateDetails() {
        guard result.status == .updateAvailable else { return }
        (onUpdateAvailable ?? Self.presentUpdateDetails)?(self)
    }

    func skipCurrentAvailableVersion() {
        guard let version = result.latestVersionLabel else { return }
        settings.skipUpdateVersion(version)
        if result.status == .updateAvailable {
            result = AppUpdateResult(
                status: .upToDate,
                checkedAt: result.checkedAt,
                currentVersion: result.currentVersion,
                latestRelease: result.latestRelease,
                preferredAsset: result.preferredAsset,
                errorMessage: nil
            )
        }
    }

    private func check(force: Bool) {
        guard !isChecking else { return }
        let checkID = UUID()
        activeCheckID = checkID
        activeCheckIsAutomatic = !force
        isChecking = true
        result = AppUpdateResult(
            status: .checking,
            checkedAt: Date(),
            currentVersion: AppVersion.current(),
            latestRelease: result.latestRelease,
            preferredAsset: result.preferredAsset,
            errorMessage: nil
        )

        checker.check(
            currentVersion: AppVersion.current(),
            includePrereleases: true,
            force: force
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.activeCheckID == checkID else { return }
                self.activeCheckID = nil
                self.activeCheckIsAutomatic = false
                self.apply(result, force: force)
            }
        }
    }

    private func apply(_ nextResult: AppUpdateResult, force: Bool) {
        isChecking = false
        if !force,
            nextResult.status == .updateAvailable,
            nextResult.latestVersionLabel == settings.skippedUpdateVersion
        {
            result = AppUpdateResult(
                status: .upToDate,
                checkedAt: nextResult.checkedAt,
                currentVersion: nextResult.currentVersion,
                latestRelease: nextResult.latestRelease,
                preferredAsset: nextResult.preferredAsset,
                errorMessage: nil
            )
            return
        }
        result = nextResult
        if nextResult.status == .updateAvailable, let version = nextResult.latestVersionLabel {
            let reminderID = "\(nextResult.preferredOpenURL?.absoluteString ?? "")|\(version)"
            guard let presenter = onUpdateAvailable ?? Self.presentUpdateDetails else { return }
            if force || !Self.announcedAutomaticUpdates.contains(reminderID) {
                Self.announcedAutomaticUpdates.insert(reminderID)
                presenter(self)
            }
        }
    }

    private func observeSettings() {
        settings.$automaticUpdateChecksEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.startAutomaticCheck()
                } else if self.activeCheckIsAutomatic || !self.isChecking {
                    self.activeCheckID = nil
                    self.activeCheckIsAutomatic = false
                    self.isChecking = false
                    self.result = self.disabledResult()
                }
            }
            .store(in: &cancellables)
    }

    private func disabledResult() -> AppUpdateResult {
        AppUpdateResult(
            status: .disabled,
            checkedAt: Date(),
            currentVersion: AppVersion.current(),
            latestRelease: result.latestRelease,
            preferredAsset: result.preferredAsset,
            errorMessage: nil
        )
    }

    static func selfTest() -> Bool {
        final class ControlledChecker: AppUpdateChecking {
            var completions: [(AppUpdateResult) -> Void] = []

            func check(currentVersion: String, includePrereleases: Bool, force: Bool, completion: @escaping (AppUpdateResult) -> Void) {
                completions.append(completion)
            }
        }
        let suite = "CodexManagerNext.update-callback-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let checker = ControlledChecker()
        let store = AppUpdateStore(settings: settings, checker: checker)
        let reply = AppUpdateResult(status: .upToDate, checkedAt: Date(), currentVersion: "1.0.0", latestRelease: nil, preferredAsset: nil, errorMessage: nil)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        store.startAutomaticCheck()
        guard checker.completions.count == 1, store.isChecking else { return false }
        settings.automaticUpdateChecksEnabled = false
        settle()
        checker.completions[0](reply)
        settle()
        guard store.result.status == .disabled, !store.isChecking else { return false }

        settings.automaticUpdateChecksEnabled = true
        settle()
        guard checker.completions.count == 2, store.isChecking else { return false }
        checker.completions[0](reply)
        settle()
        guard store.result.status == .checking, store.isChecking else { return false }
        checker.completions[1](reply)
        settle()
        guard store.result.status == .upToDate, !store.isChecking else { return false }

        store.checkNow()
        settings.automaticUpdateChecksEnabled = false
        settle()
        guard checker.completions.count == 3, store.isChecking else { return false }
        checker.completions[2](reply)
        settle()
        return store.result.status == .upToDate && !store.isChecking
    }
}
