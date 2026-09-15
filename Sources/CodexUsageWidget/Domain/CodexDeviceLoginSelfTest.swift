import Foundation
import SwiftUI

enum CodexDeviceLoginSelfTest {
    static func run() -> Bool {
        let now = Date(timeIntervalSince1970: 1_000)
        // Synthetic and deliberately invalid as an actual authorization.
        let sample = "DEMO-ONLY"
        let url = CodexDeviceCodeParser.officialURL.absoluteString
        let context = "2. Enter this one-time code (expires in 15 minutes)"
        let text = "\u{001B}[36m\(url)\u{001B}[0m\r\n\(context)\r\n\n  \u{001B}[1m\(sample)\u{001B}[0m\r\n"
        do {
            for chunkSize in [1, 2, 7, 128, 1_024] {
                var parser = CodexDeviceCodeParser(startedAt: now)
                let bytes = Array(text.utf8)
                for start in stride(from: 0, to: bytes.count, by: chunkSize) {
                    try parser.consume(Data(bytes[start..<min(start + chunkSize, bytes.count)]))
                }
                guard parser.authorization?.code == sample,
                    parser.authorization?.expiresAt == now.addingTimeInterval(900),
                    parser.authorization?.isValid(at: now.addingTimeInterval(899)) == true,
                    parser.authorization?.isValid(at: now.addingTimeInterval(900)) == false,
                    !String(describing: parser.authorization!).contains(sample)
                else { return fail("chunked output or expiration") }
            }
            var reversed = CodexDeviceCodeParser(startedAt: now)
            try reversed.consume(Data("Device code (expires in 30 seconds)\n\(sample)\r\n\(url)".utf8))
            reversed.finish()
            guard reversed.authorization?.code == sample,
                reversed.authorization?.expiresAt == now.addingTimeInterval(30)
            else { return fail("reordered output or final partial line") }
            for invalid in [
                "\(url)\n\(sample)\n",
                "\(url)\nError requesting device code\nACCESS-DENIED\n",
                "https://auth.openai.com.evil.invalid/codex/device\n\(context)\n\(sample)\n",
                "\(url)?redirect=example.invalid\n\(context)\n\(sample)\n",
                "\(url)\n\(context)\nThe request failed: \(sample)\n",
                "\(url)\n\(context)\nnot-a-code\n",
            ] {
                var parser = CodexDeviceCodeParser(startedAt: now)
                try parser.consume(Data(invalid.utf8))
                guard parser.authorization == nil else { return fail("untrusted output was accepted") }
            }
            var cumulative = CodexDeviceCodeParser(startedAt: now)
            try cumulative.consume(Data(repeating: 10, count: CodexDeviceCodeParser.maximumBytes))
            do {
                try cumulative.consume(Data([10]))
                return fail("output bound")
            } catch CodexDeviceLoginFailure.invalidResponse {}
            let a = CodexDeviceAuthorization(code: sample, url: CodexDeviceCodeParser.officialURL, expiresAt: now.addingTimeInterval(900))
            var presentation = CodexDeviceLoginPresentation(id: UUID(), profileID: "synthetic-A", targetName: "Demo A", phase: .waiting(a, .opened))
            presentation.phase = .cancelled
            guard presentation.phase.authorization == nil, presentation.profileID == "synthetic-A" else { return fail("cancelled code retention") }
            presentation.phase = .expired
            guard presentation.phase.authorization == nil, presentation.phase.canDismiss,
                !CodexDeviceLoginPhase.verifying.canDismiss
            else { return fail("terminal states") }
            let empty = UsageSnapshot.empty
            guard !CodexDeviceLoginVerification.hasFreshQuota(empty, since: .distantPast) else { return fail("empty limits") }
            let snapshot = UsageSnapshot(
                refreshedAt: now, account: nil, limitId: "codex", limitName: nil, quotaReadSucceeded: true,
                fiveHourQuota: RateWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: now.addingTimeInterval(3600)),
                sevenDayQuota: nil, monthlyQuota: nil, credits: nil, cloudLifetimeTokens: nil, local: nil, taskBoard: nil, messages: [])
            guard CodexDeviceLoginVerification.hasFreshQuota(snapshot, since: now),
                !CodexDeviceLoginVerification.hasFreshQuota(snapshot, since: now.addingTimeInterval(1))
            else { return fail("stale limits") }
        } catch { return fail("unexpected parser failure") }
        print("device login parser and verification self-test passed")
        return true
    }

    private static func fail(_ reason: String) -> Bool {
        print("device login self-test failed: \(reason)")
        return false
    }
}

@MainActor enum CodexDeviceLoginPreviewRenderer {
    static func render(to directory: URL) -> Bool {
        let now = Date()
        let authorization = CodexDeviceAuthorization(code: "DEMO-ONLY", url: CodexDeviceCodeParser.officialURL, expiresAt: now.addingTimeInterval(872))
        let states: [(String, CodexDeviceLoginPhase)] = [
            ("ready", .waiting(authorization, .opened)), ("browser-unavailable", .waiting(authorization, .unavailable)),
            ("expired", .expired), ("verifying", .verifying), ("quota-pending", .quotaPending),
            ("mismatch", .failed(.identityMismatch)), ("cancelled", .cancelled), ("completed", .completed),
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for language in WidgetLanguage.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    for (name, phase) in states {
                        let target = language.text("合成演示账号 · 长昵称用于检查换行 · A", "Synthetic demonstration account with a long display name · A")
                        let presentation = CodexDeviceLoginPresentation(id: UUID(), profileID: "synthetic-A", targetName: target, phase: phase)
                        let view = CodexDeviceLoginView(presentation: presentation, language: language, isBusy: !phase.canDismiss)
                            .preferredColorScheme(scheme)
                            .environment(\.controlActiveState, .key)
                        let width: CGFloat = language == .en ? 380 : 520
                        try WorkspacePreviewRenderer.renderView(
                            view, size: CGSize(width: width, height: 760), scheme: scheme,
                            to: directory.appendingPathComponent("\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-\(name).png"))
                    }
                }
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-account-layout-\(UUID().uuidString)")
            let suite = "AiGoodBro.device-layout.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            let catalog = PaletteCatalog.loadFromMainBundle()
            let settings = AppSettings(defaults: defaults, paletteCatalog: catalog)
            settings.workspaceDisplayMode = .professional
            let store = WorkspacePreviewRenderer.fixtureStore(accountCount: 3, root: root)
            store.setDeviceLoginLayoutPreview()
            for language in WidgetLanguage.allCases {
                settings.language = language
                for scheme in [ColorScheme.light, .dark] {
                    settings.themeMode = scheme == .dark ? .dark : .light
                    for layout in [AccountWorkspaceLayout.rows, .cards] {
                        settings.accountWorkspaceLayout = layout
                        let view = CodexAccountManagerView(store: store, settings: settings, paletteCatalog: catalog, previewOpenCodexWorkspace: true)
                        let capture = try WorkspaceScreenshotExporter.render(view.screenshotContent.environment(\.controlActiveState, .key), width: 980, scheme: scheme)
                        try capture.png.write(to: directory.appendingPathComponent("accounts-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-\(layout.rawValue).png"))
                    }
                }
            }
            print("Rendered 32 device login panels and 8 account layouts with synthetic data only")
            return true
        } catch {
            print("Device login preview render failed")
            return false
        }
    }
    static func showInteractive() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "AiGoodBro · 设备授权候选 · 合成验收"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DeviceLoginInteractionFixture())
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

}

private struct DeviceLoginInteractionFixture: View {
    @State private var presentation = CodexDeviceLoginPresentation(
        id: UUID(), profileID: "synthetic-A", targetName: "合成账号 A · 长昵称验收",
        phase: .waiting(CodexDeviceAuthorization(code: "DEMO-ONLY", url: CodexDeviceCodeParser.officialURL, expiresAt: Date().addingTimeInterval(900)), .opened))
    @State private var copies = 0
    @State private var reopens = 0
    @State private var generations = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("合成验收 · 复制 \(copies) · 重开 \(reopens) · 会话 \(generations)").font(.caption)
                Spacer()
                Button("模拟过期") { presentation.phase = .expired }
                Button("模拟额度待定") { presentation.phase = .quotaPending }
            }.padding(10)
            Divider()
            CodexDeviceLoginView(
                presentation: presentation, language: .zh, isBusy: !presentation.phase.canDismiss,
                copy: {
                    copies += 1
                    presentation.copiedUntil = Date().addingTimeInterval(3)
                },
                reopen: { reopens += 1 }, copyURL: {},
                retry: {
                    generations += 1
                    presentation.phase = .waiting(
                        CodexDeviceAuthorization(code: "DEMO-ONLY", url: CodexDeviceCodeParser.officialURL, expiresAt: Date().addingTimeInterval(900)), .opened)
                },
                verify: { presentation.phase = .completed }, cancel: { presentation.phase = .cancelled },
                close: { NSApplication.shared.terminate(nil) }
            )
        }
    }
}
