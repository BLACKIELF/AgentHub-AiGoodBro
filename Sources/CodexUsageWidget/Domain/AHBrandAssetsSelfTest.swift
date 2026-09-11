import AppKit
import Foundation

/// Verifies the AiGoodBro brand entries stay consistent after the 0911v1
/// icon redesign: the identity constants, the bundled runtime PNG, the bundled
/// app icon that Finder and the Dock actually use, and the codexU MIT
/// attribution required by the licence.
enum AHBrandAssetsSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        expect(AHBrandIdentity.displayName == "AiGoodBro", "display name must stay AiGoodBro")
        expect(AHBrandIdentity.shortName == "AH", "short identifier must stay AH")
        expect(AHBrandIdentity.workspaceName == "AgentHub", "workspace name must stay AgentHub")
        expect(
            AHBrandIdentity.statusItemTooltip(description: "d", action: "a") == "AiGoodBro · d · a",
            "status item tooltip must keep the AiGoodBro prefix"
        )

        guard let resources = Bundle.main.resourceURL else {
            print("brand-assets self-test failed: bundle resource URL unavailable")
            return false
        }
        let iconURL = resources.appendingPathComponent("codexU-icon.png")
        expect(FileManager.default.fileExists(atPath: iconURL.path), "bundled runtime brand icon codexU-icon.png must exist")
        if let data = try? Data(contentsOf: iconURL), let image = NSImage(data: data) {
            let pixelWidth = image.representations.first?.pixelsWide ?? 0
            let pixelHeight = image.representations.first?.pixelsHigh ?? 0
            expect(pixelWidth == 1024 && pixelHeight == 1024, "runtime brand icon must stay 1024x1024")
            expect(image.representations.first?.hasAlpha == true, "runtime brand icon must keep an alpha channel")
        } else {
            failures.append("bundled runtime brand icon must decode as an image")
        }

        // Finder and the Dock use the .icns, not the PNG, so it needs its own
        // check. The Makefile renames the source to AiGoodBro.icns at bundle time.
        let appIconURL = resources.appendingPathComponent("AiGoodBro.icns")
        expect(
            FileManager.default.fileExists(atPath: appIconURL.path),
            "bundled app icon AiGoodBro.icns must exist")
        if let data = try? Data(contentsOf: appIconURL), let image = NSImage(data: data) {
            expect(
                image.representations.contains { $0.pixelsWide >= 512 },
                "app icon must keep a representation of at least 512px")
        } else {
            failures.append("bundled app icon must decode as an image")
        }

        // The codexU MIT attribution is a licence obligation, so assert it
        // instead of trusting the notice file to stay in place.
        let noticesURL = resources.appendingPathComponent("THIRD_PARTY_NOTICES.txt")
        if let notices = try? String(contentsOf: noticesURL, encoding: .utf8) {
            expect(
                notices.contains("shanggqm/codexU"),
                "third-party notices must keep the codexU source attribution")
            expect(
                notices.contains("MIT License"),
                "third-party notices must keep the codexU MIT licence text")
        } else {
            failures.append("bundled THIRD_PARTY_NOTICES.txt must be readable")
        }

        for failure in failures {
            print("brand-assets self-test failed: \(failure)")
        }
        return failures.isEmpty
    }
}
