import Cocoa
import Foundation

enum CodexExecutable {
    static let preferredPathKey = "CodexManagerNext.runtime.codexPath"

    static func bundledPath(fileManager: FileManager = .default) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { return nil }
        return bundledPath(in: appURL, fileManager: fileManager)
    }

    static func bundledPath(in appURL: URL, fileManager: FileManager = .default) -> String? {
        // ChatGPT 26.928 moved its signed CLI into the codex-cli package.
        let paths = [
            "Contents/Resources/codex-cli/bin/codex",
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex",
        ]
        return paths.map { appURL.appendingPathComponent($0).path }
            .first(where: { fileManager.isExecutableFile(atPath: $0) })
    }

    static func independentPath(fileManager: FileManager = .default) -> String? {
        let preferred = UserDefaults.standard.string(forKey: preferredPathKey)
        let candidates = [
            preferred,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/packages/standalone/current/bin/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex",
        ].compactMap { $0 }
        return candidates.first { $0.hasPrefix("/") && fileManager.isExecutableFile(atPath: $0) }
    }

    static func candidates(fileManager: FileManager = .default) -> [String] {
        var candidates: [String] = []
        if let preferred = UserDefaults.standard.string(forKey: preferredPathKey) {
            candidates.append(preferred)
        }
        if let bundled = bundledPath(fileManager: fileManager) {
            candidates.append(bundled)
        }
        candidates.append(contentsOf: [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/packages/standalone/current/bin/codex").path,
        ])
        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex",
        ])
        var seen = Set<String>()
        return candidates.filter {
            $0.hasPrefix("/") && seen.insert($0).inserted && fileManager.isExecutableFile(atPath: $0)
        }
    }

    static func path(fileManager: FileManager = .default) -> String? {
        candidates(fileManager: fileManager).first
    }

    static func version() -> String? {
        guard let executable = path() else { return nil }
        guard
            let data = try? BoundedLocalProcess.run(
                executable: URL(fileURLWithPath: executable),
                arguments: ["--version"], maximumOutputBytes: 4 * 1_024, timeout: 2)
        else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
