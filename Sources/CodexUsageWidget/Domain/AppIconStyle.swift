import AppKit

enum AppIconStyle: String, CaseIterable, Identifiable {
    case mascot

    static let storageKey = "AiGoodBro.appIconStyle.v1"
    static let `default` = AppIconStyle.mascot

    var id: String { rawValue }

    var resourceName: String { "AiGoodBro" }

    func title(_ language: WidgetLanguage) -> String { "AiGoodBro" }

    static func storedOrDefault(defaults: UserDefaults = .standard) -> Self {
        // Retired palette selections migrate to the approved brand asset.
        if defaults.string(forKey: storageKey) != Self.default.rawValue {
            Self.default.persist(defaults: defaults)
        }
        return .default
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    @discardableResult
    func applyToRunningApp() -> Bool {
        // Pure command-line self-tests intentionally do not create an
        // NSApplication. Accessing NSApp.applicationIconImage in that state
        // traps, so applying an icon is only meaningful once an app exists.
        guard let application = NSApp else { return false }
        let bundle = Bundle.main
        let image =
            bundle.image(forResource: resourceName)
            ?? NSImage(contentsOf: bundle.url(forResource: resourceName, withExtension: "icns") ?? URL(fileURLWithPath: "/dev/null"))
        guard let image else { return false }
        application.applicationIconImage = image
        return true
    }
}

enum AppIconStyleSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        expect(AppIconStyle.allCases.count == 1, "one approved brand icon")
        expect(AppIconStyle.default == .mascot, "default is approved mascot")
        let defaults = UserDefaults(suiteName: "AiGoodBro.appIconStyle.self-test")!
        defaults.removePersistentDomain(forName: "AiGoodBro.appIconStyle.self-test")
        defer { defaults.removePersistentDomain(forName: "AiGoodBro.appIconStyle.self-test") }
        for oldValue in ["warmWhite", "deepPlum", "sageGreen", "graphite", "champagne", "not-a-style"] {
            defaults.set(oldValue, forKey: AppIconStyle.storageKey)
            expect(AppIconStyle.storedOrDefault(defaults: defaults) == .mascot, "retired style migrates")
            expect(defaults.string(forKey: AppIconStyle.storageKey) == "mascot", "migration persists")
        }
        if NSApp == nil {
            expect(!AppIconStyle.default.applyToRunningApp(), "headless icon apply safely reports no running app")
        }
        if failures.isEmpty {
            print("app icon style self-test passed")
            return true
        }
        failures.forEach { print("app icon style self-test failed: \($0)") }
        return false
    }
}
