import Foundation

enum NextFeatureDefaults {
    static func isEnabled(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    static func selfTest() -> Bool {
        let suite = "CodexManagerNext.feature-defaults-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "feature"
        guard isEnabled(key, in: defaults), defaults.persistentDomain(forName: suite)?[key] == nil else { return false }
        defaults.set(false, forKey: key)
        guard !isEnabled(key, in: defaults) else { return false }
        defaults.set(true, forKey: key)
        defaults.setVolatileDomain([key: "NO"], forName: UserDefaults.argumentDomain)
        return !isEnabled(key, in: defaults) && defaults.persistentDomain(forName: suite)?[key] as? Bool == true
    }
}

enum NextSetupStep: Int, CaseIterable, Identifiable, Codable {
    case accounts
    case features
    case notifications
    case ready
    case runtime
    case updates

    // Keep persisted 0...3 values from earlier versions while inserting the new first page.
    static let allCases: [Self] = [.accounts, .runtime, .features, .notifications, .ready, .updates]
    var index: Int { NextSetupGuideScope.full.steps.firstIndex(of: self) ?? 0 }
    var previous: Self { NextSetupGuideScope.full.previous(self) }
    var next: Self { NextSetupGuideScope.full.next(self) }

    var id: Int { rawValue }

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .runtime: return language.text("准备运行环境", "Prepare your tools")
        case .accounts: return language.text("连接工具与账号", "Connect tools & accounts")
        case .features: return language.text("默认功能", "Your features")
        case .notifications: return language.text("连接通知", "Connect alerts")
        case .ready: return language.text("开始使用", "Ready to go")
        case .updates: return language.text("新功能设置", "New features")
        }
    }

    var symbol: String {
        switch self {
        case .runtime: return "shippingbox"
        case .accounts: return "person.2"
        case .features: return "switch.2"
        case .notifications: return "bell.badge"
        case .ready: return "checkmark.circle"
        case .updates: return "sparkles"
        }
    }
}

enum NextSetupGuideScope: String, Codable {
    case full
    case connections
    case audience
    case returning

    var steps: [NextSetupStep] {
        switch self {
        case .full: return [.accounts, .runtime, .features, .notifications, .ready]
        case .connections: return [.notifications, .ready]
        case .audience: return []
        case .returning: return [.notifications, .updates, .ready]
        }
    }

    func previous(_ step: NextSetupStep) -> NextSetupStep {
        guard !steps.isEmpty else { return step }
        return steps[max(0, (steps.firstIndex(of: step) ?? 0) - 1)]
    }

    func next(_ step: NextSetupStep) -> NextSetupStep {
        guard !steps.isEmpty else { return step }
        return steps[min(steps.count - 1, (steps.firstIndex(of: step) ?? 0) + 1)]
    }
}

enum NextSetupAudience: String, Codable {
    case newUser
    case returningUser

    var scope: NextSetupGuideScope { self == .newUser ? .full : .returning }
}

enum NextSetupGuideOutcome {
    case completed
    case deferred
}

struct NextSetupProgress: Equatable {
    var step: NextSetupStep = .accounts
    var dismissed = false
    var completed = false

    var shouldPresentAutomatically: Bool { !dismissed && !completed }

    private static let stepKey = "CodexManagerNext.setup.step"
    private static let dismissedKey = "CodexManagerNext.setup.dismissed"
    private static let completedKey = "CodexManagerNext.setup.completed"

    static func load(from defaults: UserDefaults) -> Self {
        Self(
            step: defaults.object(forKey: stepKey) == nil ? .accounts : (NextSetupStep(rawValue: defaults.integer(forKey: stepKey)) ?? .runtime),
            dismissed: defaults.bool(forKey: dismissedKey),
            completed: defaults.bool(forKey: completedKey)
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(step.rawValue, forKey: Self.stepKey)
        defaults.set(dismissed, forKey: Self.dismissedKey)
        defaults.set(completed, forKey: Self.completedKey)
    }

    static func selfTest() -> Bool {
        let suite = "CodexManagerNext.setup-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        guard load(from: defaults).shouldPresentAutomatically, load(from: defaults).step == .accounts,
            NextSetupStep.accounts.next == .runtime, NextSetupStep.runtime.previous == .accounts
        else { return false }
        defaults.set(0, forKey: stepKey)
        guard load(from: defaults).step == .accounts else { return false }
        let paused = Self(step: .notifications, dismissed: true)
        paused.save(to: defaults)
        guard load(from: defaults) == paused, !load(from: defaults).shouldPresentAutomatically else { return false }
        Self(step: .ready, completed: true).save(to: defaults)
        guard load(from: defaults).completed, !load(from: defaults).shouldPresentAutomatically else { return false }
        defaults.set(999, forKey: stepKey)
        return load(from: defaults).step == .runtime && load(from: defaults).completed
    }
}
