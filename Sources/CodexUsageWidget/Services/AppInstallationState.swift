import Darwin
import Foundation

/// File identities provide a stable restart baseline without relying on version or mtime.
struct AppInstallationFileIdentity: Codable, Equatable {
    var device: UInt64
    var inode: UInt64
}

struct AppInstallationIdentity: Codable, Equatable {
    var bundleIdentifier: String
    var bundle: AppInstallationFileIdentity
    var executable: AppInstallationFileIdentity

    var eventID: String {
        "files:\(bundleIdentifier):\(bundle.device):\(bundle.inode):\(executable.device):\(executable.inode)"
    }
}

struct AppInstallationReceipt: Codable {
    var schemaVersion: Int
    var installationID: String
    var bundleIdentifier: String
    var bundleIdentity: AppInstallationFileIdentity
    var executableIdentity: AppInstallationFileIdentity

    func matchingID(for identity: AppInstallationIdentity) -> String? {
        guard schemaVersion == 1, let uuid = UUID(uuidString: installationID),
            bundleIdentifier == identity.bundleIdentifier,
            bundleIdentity == identity.bundle, executableIdentity == identity.executable
        else { return nil }
        return uuid.uuidString.lowercased()
    }
}

struct AppInstallationContext {
    var identity: AppInstallationIdentity?
    var receipt: AppInstallationReceipt?

    /// Only the normal application owner calls this. Preview/settings fixtures inject data.
    static func observe(bundle: Bundle = .main, receiptURL: URL) -> Self {
        let manager = FileManager.default
        func fileIdentity(_ url: URL, type: FileAttributeType) -> AppInstallationFileIdentity? {
            guard let values = try? manager.attributesOfItem(atPath: url.path),
                values[.type] as? FileAttributeType == type,
                let device = values[.systemNumber] as? NSNumber,
                let inode = values[.systemFileNumber] as? NSNumber
            else { return nil }
            return .init(device: device.uint64Value, inode: inode.uint64Value)
        }
        guard let identifier = bundle.bundleIdentifier, !identifier.isEmpty,
            let executableURL = bundle.executableURL,
            let bundleIdentity = fileIdentity(bundle.bundleURL, type: .typeDirectory),
            let executableIdentity = fileIdentity(executableURL, type: .typeRegular)
        else { return .init() }
        let identity = AppInstallationIdentity(bundleIdentifier: identifier, bundle: bundleIdentity, executable: executableIdentity)
        var receipt: AppInstallationReceipt?
        if let values = try? manager.attributesOfItem(atPath: receiptURL.path),
            values[.type] as? FileAttributeType == .typeRegular,
            let size = values[.size] as? NSNumber, size.intValue <= 16_384
        {
            let descriptor = open(receiptURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if descriptor >= 0 {
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var information = stat()
                if fstat(descriptor, &information) == 0,
                    information.st_mode & S_IFMT == S_IFREG, information.st_size <= 16_384,
                    let data = try? handle.read(upToCount: 16_385), data.count <= 16_384
                {
                    receipt = try? JSONDecoder().decode(AppInstallationReceipt.self, from: data)
                }
            }
        }
        return .init(identity: identity, receipt: receipt)
    }
}

/// Kept separate from earlier full-onboarding JSON and feature preferences.
struct InstallationOnboardingState: Codable, Equatable {
    enum Status: String, Codable { case pending, completed, deferred }
    static let storageKey = "CodexManagerNext.installationOnboarding.v1"
    var installationID: String?
    var observedIdentity: AppInstallationIdentity?
    var scope: NextSetupGuideScope = .full
    var status: Status = .pending
    var connectionStep: NextSetupStep = .notifications
    var audience: NextSetupAudience?
    /// Stable across a file baseline being enriched with a late installation receipt.
    var eventGeneration: String?

    var shouldPresent: Bool { installationID != nil && status == .pending }
    var presentationEventID: String? { eventGeneration ?? installationID }

    func automaticScope(legacyShouldPresent: Bool) -> NextSetupGuideScope? {
        if shouldPresent { return audience?.scope ?? .audience }
        // Once installation events are tracked, old pending full setup is manual only.
        return installationID == nil && legacyShouldPresent ? .full : nil
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
            let decodedState = try? JSONDecoder().decode(Self.self, from: data)
        else { return .init() }
        var state = decodedState
        if !NextSetupGuideScope.returning.steps.contains(state.connectionStep) { state.connectionStep = .notifications }
        return state
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }

    mutating func observe(_ context: AppInstallationContext, existingUser: Bool) {
        // Unreadable evidence is not a new installation.
        guard let identity = context.identity else { return }
        if eventGeneration == nil { eventGeneration = installationID }
        let receiptID = context.receipt?.matchingID(for: identity)
        if installationID != nil, observedIdentity == identity, receiptID == nil { return }
        // A receipt becoming readable for the same files does not mean a reinstall.
        if observedIdentity == identity, installationID == identity.eventID, let receiptID {
            installationID = receiptID
            return
        }
        let eventID = receiptID ?? identity.eventID
        if installationID != eventID {
            scope = .audience
            status = .pending
            connectionStep = .notifications
            audience = nil
            eventGeneration = UUID().uuidString.lowercased()
            installationID = eventID
        }
        observedIdentity = identity
    }

    @discardableResult
    mutating func select(_ selection: NextSetupAudience, eventID: String) -> Bool {
        guard shouldPresent, presentationEventID == eventID, audience == nil else { return false }
        audience = selection
        scope = selection.scope
        connectionStep = .notifications
        return true
    }

    @discardableResult
    mutating func setConnectionStep(_ step: NextSetupStep, eventID: String) -> Bool {
        guard shouldPresent, presentationEventID == eventID, audience == .returningUser,
            NextSetupGuideScope.returning.steps.contains(step)
        else { return false }
        connectionStep = step
        return true
    }

    mutating func finish(_ outcome: NextSetupGuideOutcome, scope completedScope: NextSetupGuideScope, eventID: String?) {
        guard shouldPresent, let eventID, presentationEventID == eventID,
            audience != nil || outcome == .deferred,
            (audience?.scope ?? .audience) == completedScope
        else { return }
        status = outcome == .completed ? .completed : .deferred
    }
}
