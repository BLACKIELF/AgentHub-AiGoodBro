import CoreFoundation
import Darwin
import Foundation

/// The build/ app finds the Hub checkout beside the Next checkout. Installed
/// copies can explicitly supply CAMNEXT_HUB_CONFIG_PATH instead. No path probing
/// or configuration writes happen until the user changes participation.
struct DispatchParticipationPaths {
    static let supportDirectoryName = "CodexAccountManagerNext"
    static let snapshotFileName = "account-manager-next-v1.json"
    static let codesFileName = "dispatch-codes-v1.json"
    static let hubCheckoutName = "agent-remote-control-0828v1"
    static let hubConfigFileName = "config.json"
    static let hubConfigEnvironmentKey = "CAMNEXT_HUB_CONFIG_PATH"
    static let backupDirectoryName = "dispatch-participation-backups"
    static let lockFileName = ".dispatch-participation.lock"

    let snapshot: URL
    let hubConfig: URL
    let codes: URL

    static func supportDirectory(fileManager: FileManager = .default) -> URL {
        let base =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    static var codesURL: URL { supportDirectory().appendingPathComponent(codesFileName) }

    static func live(
        snapshot: URL,
        bundleURL: URL = Bundle.main.bundleURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        launchAgentURL: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.agenthub.arc-hub.plist")
    ) throws -> Self {
        let hubConfig: URL
        if let override = environment[hubConfigEnvironmentKey], !override.isEmpty {
            guard override.hasPrefix("/") else { throw DispatchParticipationError.hubLocation }
            hubConfig = URL(fileURLWithPath: override)
        } else if FileManager.default.fileExists(
            atPath: snapshot.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CodexAccountManagerNextHub/config.json").path)
        {
            hubConfig = snapshot.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CodexAccountManagerNextHub/config.json")
        } else {
            let buildDirectory = bundleURL.deletingLastPathComponent()
            if buildDirectory.lastPathComponent == "build" {
                hubConfig = buildDirectory.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent(hubCheckoutName, isDirectory: true).appendingPathComponent(hubConfigFileName)
            } else {
                // Installed copies cannot infer the checkout from their bundle path.
                // Discover only the user's existing named service; never evaluate its shell command.
                guard let launchAgentURL else { throw DispatchParticipationError.hubLocation }
                var info = stat()
                guard lstat(launchAgentURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                    info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
                    let data = try DispatchParticipationSync.readBoundedRegularFile(launchAgentURL, maximumBytes: 64 * 1_024),
                    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                    plist["Label"] as? String == "com.agenthub.arc-hub"
                else { throw DispatchParticipationError.hubLocation }
                if let explicit = try explicitConfigPath(in: plist) {
                    hubConfig = URL(fileURLWithPath: explicit)
                } else {
                    guard let directory = plist["WorkingDirectory"] as? String, directory.hasPrefix("/")
                    else { throw DispatchParticipationError.hubLocation }
                    hubConfig = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(hubConfigFileName)
                }
            }
        }
        return Self(snapshot: snapshot, hubConfig: hubConfig, codes: snapshot.deletingLastPathComponent().appendingPathComponent(codesFileName))
    }

    /// Parse literals only. Invalid explicit arguments must never select the legacy fallback.
    private static func explicitConfigPath(in plist: [String: Any]) throws -> String? {
        guard let raw = plist["ProgramArguments"] else { return nil }
        guard var arguments = raw as? [String], let executable = arguments.first,
            executable.hasPrefix("/")
        else { throw DispatchParticipationError.hubLocation }
        if executable == "/bin/bash" {
            // Deliberately accept only the deployed wrapper, not general shell grammar.
            guard arguments.count == 3, arguments[1] == "-c" else {
                throw DispatchParticipationError.hubLocation
            }
            let pattern = #"\Aexec (['"])(/[^'"]+)\1 --config (['"])(/[^'"]+)\3\z"#
            let command = arguments[2]
            let regex = try NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
                let binaryRange = Range(match.range(at: 2), in: command),
                let configRange = Range(match.range(at: 4), in: command)
            else { throw DispatchParticipationError.hubLocation }
            arguments = [String(command[binaryRange]), "--config", String(command[configRange])]
        }
        // Conservative literal subset, also applied to direct argv: no expansions,
        // quoting, control characters, shell operators, or nested shell invocation.
        let forbidden = CharacterSet(charactersIn: "$`\\\"';&|<>(){}[]*?~").union(.controlCharacters)
        guard arguments.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: forbidden) == nil }),
            !["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(URL(fileURLWithPath: arguments[0]).lastPathComponent),
            !arguments.contains("-c"), !arguments.contains("-lc"), !arguments.contains("--")
        else { throw DispatchParticipationError.hubLocation }
        let flags = arguments.indices.filter { arguments[$0].hasPrefix("--config") }
        guard !flags.isEmpty else { return nil }
        guard flags.count == 1, let index = flags.first, arguments[index] == "--config",
            index + 1 < arguments.count, arguments[index + 1].hasPrefix("/")
        else { throw DispatchParticipationError.hubLocation }
        return arguments[index + 1]
    }
}

/// All messages are fixed text: Foundation/POSIX errors can contain private paths.
enum DispatchParticipationError: LocalizedError {
    case hubLocation, invalidSnapshot, invalidHub, invalidCodes, identityMismatch, ambiguousAccount
    case codeExhausted, fileAccess, busy, concurrentChange, writeFailed, rolledBack, rollbackFailed

    var errorDescription: String? {
        switch self {
        case .hubLocation:
            return WidgetLanguage.storedOrAutomatic().text(
                "无法定位 Hub 配置，请从 build 目录启动或设置 CAMNEXT_HUB_CONFIG_PATH", "Hub configuration was not found. Launch from the build folder or set CAMNEXT_HUB_CONFIG_PATH.")
        case .invalidSnapshot: return WidgetLanguage.storedOrAutomatic().text("Next 快照无效，未修改调度设置", "The Next snapshot is invalid. Dispatch settings were not changed.")
        case .invalidHub: return WidgetLanguage.storedOrAutomatic().text("Hub 配置无效，未修改调度设置", "The Hub configuration is invalid. Dispatch settings were not changed.")
        case .invalidCodes: return WidgetLanguage.storedOrAutomatic().text("调度编号文件无效或存在重复映射，未修改调度设置", "Dispatch codes are invalid or duplicated. Settings were not changed.")
        case .identityMismatch:
            return WidgetLanguage.storedOrAutomatic().text("账号身份与已保存快照不一致，请刷新后重试", "The account identity does not match the saved snapshot. Refresh and try again.")
        case .ambiguousAccount:
            return WidgetLanguage.storedOrAutomatic().text(
                "无法唯一匹配 Hub 账号，请检查账号目录与编号映射", "The Hub account could not be uniquely matched. Check its profile folder and dispatch code.")
        case .codeExhausted: return WidgetLanguage.storedOrAutomatic().text("A–Z 调度编号已用尽，未修改调度设置", "All A–Z dispatch codes are in use. Settings were not changed.")
        case .fileAccess:
            return WidgetLanguage.storedOrAutomatic().text("无法安全读取调度配置，请检查文件和目录权限", "Dispatch configuration cannot be read safely. Check file and folder permissions.")
        case .busy: return WidgetLanguage.storedOrAutomatic().text("另一项参与调度同步正在进行，请稍后重试", "Another dispatch-pool sync is running. Try again shortly.")
        case .concurrentChange: return WidgetLanguage.storedOrAutomatic().text("调度配置已被其他操作修改，请刷新后重试", "Dispatch configuration changed elsewhere. Refresh and try again.")
        case .writeFailed:
            return WidgetLanguage.storedOrAutomatic().text("调度配置备份或写入失败，原配置未改变", "Could not back up or save dispatch settings. The original configuration is unchanged.")
        case .rolledBack: return WidgetLanguage.storedOrAutomatic().text("三源同步失败，已恢复本次写入前的配置", "The three-store sync failed. The previous configuration was restored.")
        case .rollbackFailed:
            return WidgetLanguage.storedOrAutomatic().text(
                "三源同步失败且回滚未完成；已保留 dispatch-participation-backups 备份，请恢复后重试",
                "The three-store sync failed and rollback is incomplete. Restore the retained dispatch-participation-backups before retrying.")
        }
    }
}

struct DispatchParticipationSync {
    static let maximumConfigurationBytes = 16 * 1_024 * 1_024
    static let maximumCatalogEntries = 26
    static let maximumCatalogFieldBytes = 128

    enum Change {
        case participation(Bool)
        case priority(Bool)
    }

    struct Identity {
        let profileID: String
        let homePath: String
        let email: String?
        let accountID: String
    }

    // Hooks exercise actual filesystem rollback in offline tests, including a
    // failure after rename. Production uses the default no-op closure.
    enum Checkpoint {
        case beforeBackup(Int)
        case beforeReplace(Int)
        case afterPreflight(Int)
        case beforeAtomicSwap(Int)
        case afterReplace(Int)
        case beforeRollback(Int)
        case afterRemovalMove(Int)
        case beforeMismatchRestore(Int)
        case afterMismatchRestore(Int)
    }

    private enum ReplacementExpectation {
        case unchecked
        case matching(Data?)
    }

    let paths: DispatchParticipationPaths
    var checkpoint: (Checkpoint) throws -> Void = { _ in }
    private static let processLock = NSLock()

    /// This is deliberately called only by the UI action, never by a loader.
    /// Backups precede every target replacement. Each file is atomic; the three
    /// renames are not a crash-atomic transaction across directories.
    func setParticipation(
        _ enabled: Bool,
        identity: Identity,
        validateSnapshot: (Data) throws -> Void = { _ in }
    ) throws -> Data {
        try apply(.participation(enabled), identity: identity, validateSnapshot: validateSnapshot)
    }

    func apply(
        _ change: Change,
        identity: Identity,
        validateSnapshot: (Data) throws -> Void = { _ in }
    ) throws -> Data {
        try Self.withSnapshotLock(at: paths.snapshot) {
            let directory = paths.snapshot.deletingLastPathComponent()
            let urls = [paths.snapshot, paths.hubConfig, paths.codes]
            guard Set(urls.map { $0.standardizedFileURL.path }).count == urls.count else {
                throw DispatchParticipationError.fileAccess
            }
            let originals = try urls.enumerated().map { try Self.read($0.element, allowMissing: $0.offset == 2) }
            guard let snapshot = originals[0], let hub = originals[1] else { throw DispatchParticipationError.fileAccess }
            try validateSnapshot(snapshot)
            let updated = try Self.prepare(change, identity: identity, snapshot: snapshot, hub: hub, codes: originals[2])
            try validateSnapshot(updated[0])

            let backups = directory.appendingPathComponent(DispatchParticipationPaths.backupDirectoryName, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            var replaced: [Int] = []
            do {
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for index in urls.indices {
                    try checkpoint(.beforeBackup(index))
                    if let original = originals[index] {
                        let backup = backups.appendingPathComponent(["snapshot.json", "hub-config.json", "dispatch-codes.json"][index])
                        try Self.replaceAtomically(original, at: backup)
                        guard try Self.read(backup) == original else { throw DispatchParticipationError.writeFailed }
                    }
                }
                let manifest = try Self.encode(["schemaVersion": 1, "codesOriginallyMissing": originals[2] == nil])
                try Self.replaceAtomically(manifest, at: backups.appendingPathComponent("manifest.json"))

                // Hub and external tools do not take this lock. Check for changes
                // before every rename and again after the complete transaction.
                for index in urls.indices {
                    try checkpoint(.beforeReplace(index))
                    for check in urls.indices {
                        let expected = replaced.contains(check) ? updated[check] : originals[check]
                        guard try Self.read(urls[check], allowMissing: check == 2) == expected else {
                            throw DispatchParticipationError.concurrentChange
                        }
                    }
                    try checkpoint(.afterPreflight(index))
                    try Self.replaceAtomically(
                        updated[index],
                        at: urls[index],
                        expectation: .matching(originals[index]),
                        checkpointIndex: index,
                        checkpoint: checkpoint
                    )
                    replaced.append(index)
                    try checkpoint(.afterReplace(index))
                }
                for index in urls.indices {
                    guard try Self.read(urls[index]) == updated[index] else { throw DispatchParticipationError.concurrentChange }
                }
            } catch {
                var rollbackSucceeded = true
                for index in replaced.reversed() {
                    do {
                        try checkpoint(.beforeRollback(index))
                        let current = try Self.read(urls[index], allowMissing: true)
                        if current == originals[index] { continue }
                        // Never roll back over an unrelated concurrent edit.
                        guard current == updated[index] else { throw DispatchParticipationError.concurrentChange }
                        if let original = originals[index] {
                            try Self.replaceAtomically(
                                original,
                                at: urls[index],
                                expectation: .matching(updated[index]),
                                checkpointIndex: index,
                                checkpoint: checkpoint
                            )
                        } else {
                            try Self.removeAtomicallyIfMatching(
                                updated[index],
                                at: urls[index],
                                checkpointIndex: index,
                                checkpoint: checkpoint
                            )
                        }
                        guard try Self.read(urls[index], allowMissing: true) == originals[index] else {
                            throw DispatchParticipationError.rollbackFailed
                        }
                    } catch { rollbackSucceeded = false }
                }
                if !rollbackSucceeded { throw DispatchParticipationError.rollbackFailed }
                if !replaced.isEmpty { throw DispatchParticipationError.rolledBack }
                if let error = error as? DispatchParticipationError { throw error }
                throw DispatchParticipationError.writeFailed
            }
            return updated[0]
        }
    }

    private static func prepare(_ change: Change, identity: Identity, snapshot: Data, hub: Data, codes: Data?) throws -> [Data] {
        var next = try object(snapshot, error: .invalidSnapshot)
        guard integer(next["schemaVersion"]) == 1,
            var profiles = next["profiles"] as? [[String: Any]],
            profiles.allSatisfy({ nonempty($0["id"]) != nil && nonempty($0["codexHomePath"]) != nil }),
            Set(profiles.compactMap { nonempty($0["id"]) }).count == profiles.count,
            let selected = profiles.first(where: { nonempty($0["id"]) == identity.profileID }),
            let email = profileEmail(selected),
            email == normalized(identity.email),
            nonempty((selected["lastSnapshot"] as? [String: Any])?["accountID"]) == identity.accountID,
            canonicalHome(selected["codexHomePath"]) == canonicalHome(identity.homePath)
        else { throw DispatchParticipationError.identityMismatch }
        let group = profiles.filter { profileEmail($0) == email }
        let groupIDs = Set(group.compactMap { nonempty($0["id"]) })
        guard
            group.allSatisfy({ profile in
                nonempty((profile["lastSnapshot"] as? [String: Any])?["accountID"]) == identity.accountID
            })
        else { throw DispatchParticipationError.identityMismatch }
        guard
            group.allSatisfy({ profile in
                ["automaticSwitchParticipation", "prioritizeDispatch"].allSatisfy {
                    profile[$0] == nil || boolean(profile[$0]) != nil
                }
            })
        else { throw DispatchParticipationError.invalidSnapshot }
        let participationStates = Set(group.map { boolean($0["automaticSwitchParticipation"]) != false })
        let priorityStates = Set(group.map { boolean($0["prioritizeDispatch"]) == true })
        guard participationStates.count == 1, priorityStates.count == 1 else {
            throw DispatchParticipationError.invalidSnapshot
        }
        let enabled: Bool
        let priority: Bool?
        switch change {
        case .participation(let participates):
            enabled = participates
            priority = participates ? nil : false
        case .priority(let prioritizes):
            // Opting into priority also joins dispatch. Removing priority never
            // opts an excluded account in or removes an existing participant.
            enabled = prioritizes || participationStates.first == true
            priority = prioritizes
        }

        var hubObject = try object(hub, error: .invalidHub)
        guard var accounts = hubObject["accounts"] as? [[String: Any]],
            accounts.allSatisfy({
                nonempty($0["alias"]) != nil && canonicalHome($0["home"]) != nil
                    && ($0["dispatchDisabled"] == nil || boolean($0["dispatchDisabled"]) != nil)
            }),
            Set(accounts.compactMap { normalized($0["alias"]) }).count == accounts.count
        else { throw DispatchParticipationError.invalidHub }
        let matches = accounts.indices.filter { index in
            group.contains { canonicalHome($0["codexHomePath"]) == canonicalHome(accounts[index]["home"]) }
        }
        // An account absent from Hub still needs a working opt-out. No new Hub
        // identity is created, and entries belonging to other homes stay intact.
        if !enabled && matches.isEmpty {
            var catalog = try codes.map { try object($0, error: .invalidCodes) } ?? ["schemaVersion": 1, "accounts": []]
            try normalizeCatalog(&catalog, profiles: profiles, hub: hubObject, accounts: accounts)
            var entries = try validatedEntries(catalog)
            for index in entries.indices where groupIDs.contains(nonempty(entries[index]["profileId"]) ?? "") {
                guard entries[index]["email"] == nil || normalized(entries[index]["email"]) == email,
                    !accounts.contains(where: { normalized($0["alias"]) == normalized(entries[index]["alias"]) })
                else { throw DispatchParticipationError.ambiguousAccount }
                entries[index]["active"] = false
            }
            for index in profiles.indices where groupIDs.contains(nonempty(profiles[index]["id"]) ?? "") {
                profiles[index]["automaticSwitchParticipation"] = false
                if let priority { profiles[index]["prioritizeDispatch"] = priority }
            }
            next["profiles"] = profiles
            catalog["accounts"] = entries
            try validatePreflightCatalog(catalog)
            return [try encode(next), hub, try encode(catalog)]
        }
        // Exclusion can safely cover every validated home of the same identity.
        // Joining still requires one unambiguous execution home.
        guard matches.count == 1 || (!enabled && !matches.isEmpty), let accountIndex = matches.first,
            let alias = nonempty(accounts[accountIndex]["alias"])
        else { throw DispatchParticipationError.ambiguousAccount }
        let homeProfiles = group.filter { canonicalHome($0["codexHomePath"]) == canonicalHome(accounts[accountIndex]["home"]) }
        guard homeProfiles.count == 1, let profileID = nonempty(homeProfiles[0]["id"]) else {
            throw DispatchParticipationError.ambiguousAccount
        }

        var catalog = try codes.map { try object($0, error: .invalidCodes) } ?? ["schemaVersion": 1, "accounts": []]
        try normalizeCatalog(&catalog, profiles: profiles, hub: hubObject, accounts: accounts)
        var entries = try validatedEntries(catalog)
        let matchedEntries = entries.indices.filter {
            groupIDs.contains(nonempty(entries[$0]["profileId"]) ?? "") || normalized(entries[$0]["alias"]) == normalized(alias)
        }
        guard matchedEntries.count <= 1 else { throw DispatchParticipationError.ambiguousAccount }
        if let index = matchedEntries.first {
            guard groupIDs.contains(nonempty(entries[index]["profileId"]) ?? ""),
                normalized(entries[index]["alias"]) == normalized(alias),
                entries[index]["email"] == nil || normalized(entries[index]["email"]) == email
            else { throw DispatchParticipationError.ambiguousAccount }
            if enabled {
                entries[index]["profileId"] = profileID
                entries[index]["active"] = true
            } else {
                // The code is an account identity, while participation is
                // represented by the snapshot and Hub's dispatchDisabled flag.
                // Retaining it prevents an opt-out/opt-in cycle from silently
                // changing a user's dispatch letter.
                entries[index]["active"] = false
            }
        } else if enabled {
            let highest = entries.compactMap { nonempty($0["code"])?.utf8.first }.max().map(Int.init) ?? 64
            guard highest < 90 else { throw DispatchParticipationError.codeExhausted }
            entries.append([
                "code": String(UnicodeScalar(highest + 1)!),
                "alias": alias,
                "profileId": profileID,
                "priority": try nextPriority(after: entries),
                "active": true,
            ])
        }

        for index in profiles.indices where groupIDs.contains(nonempty(profiles[index]["id"]) ?? "") {
            profiles[index]["automaticSwitchParticipation"] = enabled
            if let priority { profiles[index]["prioritizeDispatch"] = priority }
        }
        next["profiles"] = profiles
        for index in matches { accounts[index]["dispatchDisabled"] = !enabled }
        hubObject["accounts"] = accounts
        catalog["accounts"] = entries
        try validatePreflightCatalog(catalog)
        return try [next, hubObject, catalog].map(encode)
    }

    static func validatedEntries(_ object: [String: Any]) throws -> [[String: Any]] {
        guard integer(object["schemaVersion"]) == 1,
            let entries = object["accounts"] as? [[String: Any]],
            entries.count <= maximumCatalogEntries
        else {
            throw DispatchParticipationError.invalidCodes
        }
        var codes = Set<String>()
        var aliases = Set<String>()
        var profileIDs = Set<String>()
        for entry in entries {
            guard let code = nonempty(entry["code"]), code.utf8.count == 1,
                code.utf8.allSatisfy({ (65...90).contains($0) }),
                let alias = normalized(entry["alias"]), let profileID = nonempty(entry["profileId"]),
                alias.utf8.count <= maximumCatalogFieldBytes,
                profileID.utf8.count <= maximumCatalogFieldBytes,
                codes.insert(code).inserted, aliases.insert(alias).inserted, profileIDs.insert(profileID).inserted,
                entry["email"] == nil || normalized(entry["email"]) != nil,
                entry["priority"] == nil || integer(entry["priority"]) != nil,
                entry["active"] == nil || boolean(entry["active"]) != nil
            else { throw DispatchParticipationError.invalidCodes }
        }
        return entries
    }

    private static func normalizeCatalog(
        _ catalog: inout [String: Any],
        profiles: [[String: Any]],
        hub: [String: Any],
        accounts: [[String: Any]]
    ) throws {
        guard integer(catalog["schemaVersion"]) == 1 else { throw DispatchParticipationError.invalidCodes }
        var entries = try validatedEntries(catalog)
        var priority = try nextPriority(after: entries)
        for index in entries.indices where entries[index]["priority"] == nil {
            entries[index]["priority"] = priority
            if priority < Int.max { priority += 1 }
        }
        catalog["accounts"] = entries

        if let value = catalog["snapshotMaxAgeSeconds"] {
            guard validPositiveNumber(value) else { throw DispatchParticipationError.invalidCodes }
        } else {
            catalog["snapshotMaxAgeSeconds"] = 45
        }

        var minimums: [String: Any]
        if let existing = catalog["minimumRemainingPercent"] {
            guard let decoded = existing as? [String: Any] else { throw DispatchParticipationError.invalidCodes }
            minimums = decoded
        } else {
            minimums = [:]
        }
        for (key, minimum) in [("fiveHour", 0.0), ("sevenDay", 0.0)] {
            if let existing = minimums[key] {
                guard validRemainingPercent(existing, minimum: minimum) else {
                    throw DispatchParticipationError.invalidCodes
                }
            } else {
                minimums[key] = Int(minimum)
            }
        }
        catalog["minimumRemainingPercent"] = minimums

        var centralAliases: [String]
        if let existing = catalog["centralAliases"] {
            guard let decoded = existing as? [String], decoded.allSatisfy({ nonempty($0) != nil }) else {
                throw DispatchParticipationError.invalidCodes
            }
            centralAliases = decoded.compactMap(nonempty)
        } else {
            centralAliases = []
        }
        let systemHomes = Set(
            profiles.filter { boolean($0["isSystemProfile"]) == true }.compactMap { canonicalHome($0["codexHomePath"]) }
        )
        let derivedCentralAliases = accounts.compactMap { account -> String? in
            guard let home = canonicalHome(account["home"]), systemHomes.contains(home) else { return nil }
            return nonempty(account["alias"])
        }.sorted()
        var knownCentralAliases = Set(centralAliases.compactMap(normalized))
        for alias in derivedCentralAliases where knownCentralAliases.insert(alias.lowercased()).inserted {
            centralAliases.append(alias)
        }
        catalog["centralAliases"] = centralAliases

        if let existing = catalog["hubProjects"] {
            try validateHubProjects(existing)
        } else {
            catalog["hubProjects"] = try canonicalHubProjects(from: hub)
        }
    }

    private static func nextPriority(after entries: [[String: Any]]) throws -> Int {
        let values = try entries.compactMap { entry -> Int? in
            guard let value = entry["priority"] else { return nil }
            guard let integer = integer(value) else { throw DispatchParticipationError.invalidCodes }
            return integer
        }
        guard let maximum = values.max() else { return 1 }
        return maximum < Int.max ? maximum + 1 : Int.max
    }

    private static func validPositiveNumber(_ value: Any) -> Bool {
        guard let number = number(value) else { return false }
        return number.isFinite && number > 0
    }

    private static func validRemainingPercent(_ value: Any, minimum: Double) -> Bool {
        guard let number = number(value) else { return false }
        return number.isFinite && number >= minimum && number <= 100
    }

    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func canonicalHubProjects(from hub: [String: Any]) throws -> [String: Any] {
        guard let projects = hub["projects"] as? [String: Any] else { throw DispatchParticipationError.invalidHub }
        var aliasesByPath: [String: String] = [:]
        for (rawAlias, rawPath) in projects {
            guard let alias = nonempty(rawAlias), let path = canonicalHome(rawPath) else {
                throw DispatchParticipationError.invalidHub
            }
            if let current = aliasesByPath[path], current <= alias { continue }
            aliasesByPath[path] = alias
        }
        return aliasesByPath.reduce(into: [String: Any]()) { result, entry in
            result[entry.value] = entry.key
        }
    }

    private static func validateHubProjects(_ value: Any) throws {
        guard let projects = value as? [String: Any] else { throw DispatchParticipationError.invalidCodes }
        for (alias, path) in projects {
            guard nonempty(alias) != nil, canonicalHome(path) != nil else {
                throw DispatchParticipationError.invalidCodes
            }
        }
    }

    private static func validatePreflightCatalog(_ catalog: [String: Any]) throws {
        guard integer(catalog["schemaVersion"]) == 1,
            let snapshotAge = catalog["snapshotMaxAgeSeconds"], validPositiveNumber(snapshotAge),
            let minimums = catalog["minimumRemainingPercent"] as? [String: Any],
            let fiveHour = minimums["fiveHour"], validRemainingPercent(fiveHour, minimum: 0),
            let sevenDay = minimums["sevenDay"], validRemainingPercent(sevenDay, minimum: 0),
            let centralAliases = catalog["centralAliases"] as? [String],
            centralAliases.allSatisfy({ nonempty($0) != nil })
        else { throw DispatchParticipationError.invalidCodes }
        guard let hubProjects = catalog["hubProjects"] else { throw DispatchParticipationError.invalidCodes }
        try validateHubProjects(hubProjects)
        let entries = try validatedEntries(catalog)
        guard entries.allSatisfy({ integer($0["priority"]) != nil }) else {
            throw DispatchParticipationError.invalidCodes
        }
    }

    private static func profileEmail(_ profile: [String: Any]) -> String? {
        normalized((profile["lastSnapshot"] as? [String: Any])?["email"])
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ value: Any?) -> String? { nonempty(value)?.lowercased() }

    private static func canonicalHome(_ value: Any?) -> String? {
        guard let path = nonempty(value), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let result = Int(number.stringValue)
        else { return nil }
        return result
    }

    private static func object(_ data: Data, error: DispatchParticipationError) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw error }
        return object
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw DispatchParticipationError.writeFailed }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        _ = try self.object(data, error: .writeFailed)
        return data
    }

    static func readBoundedRegularFile(
        _ url: URL,
        maximumBytes: Int = maximumConfigurationBytes,
        allowMissing: Bool = false
    ) throws -> Data? {
        guard maximumBytes > 0 else { throw DispatchParticipationError.fileAccess }
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            if allowMissing && errno == ENOENT { return nil }
            throw DispatchParticipationError.fileAccess
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
            (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            metadata.st_size >= 0, metadata.st_size <= off_t(maximumBytes)
        else { throw DispatchParticipationError.fileAccess }
        do {
            var result = Data()
            while result.count <= maximumBytes {
                let remaining = maximumBytes + 1 - result.count
                guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)), !chunk.isEmpty else {
                    break
                }
                result.append(chunk)
            }
            guard result.count <= maximumBytes,
                result.count == Int(metadata.st_size)
            else { throw DispatchParticipationError.fileAccess }
            return result
        } catch { throw DispatchParticipationError.fileAccess }
    }

    private static func read(_ url: URL, allowMissing: Bool = false) throws -> Data? {
        try readBoundedRegularFile(url, maximumBytes: maximumConfigurationBytes, allowMissing: allowMissing)
    }

    /// Shares the exact synchronization boundary used by the three-file dispatch
    /// transaction. Callers must retain this lock for the entire read/modify/write
    /// sequence and use writeSnapshot's compare-and-swap expectation.
    static func withSnapshotLock<T>(at snapshotURL: URL, _ body: () throws -> T) throws -> T {
        guard processLock.try() else { throw DispatchParticipationError.busy }
        defer { processLock.unlock() }
        let lockURL = snapshotURL.deletingLastPathComponent()
            .appendingPathComponent(DispatchParticipationPaths.lockFileName)
        let descriptor = lockURL.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600) }
        guard descriptor >= 0 else { throw DispatchParticipationError.fileAccess }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
            info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(),
            info.st_nlink == 1,
            info.st_mode & 0o077 == 0
        else { throw DispatchParticipationError.fileAccess }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw DispatchParticipationError.busy }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    static func readSnapshot(at snapshotURL: URL) throws -> Data? {
        try read(snapshotURL, allowMissing: true)
    }

    static func writeSnapshot(_ data: Data, at snapshotURL: URL, replacing original: Data?) throws {
        try replaceAtomically(data, at: snapshotURL, expectation: .matching(original))
    }

    private static func replaceAtomically(
        _ data: Data,
        at url: URL,
        expectation: ReplacementExpectation = .unchecked,
        checkpointIndex: Int? = nil,
        checkpoint: ((Checkpoint) throws -> Void)? = nil
    ) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".camnext-dispatch-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw DispatchParticipationError.writeFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var removeTemporary = true
        defer {
            try? handle.close()
            if removeTemporary {
                temporary.path.withCString { _ = Darwin.unlink($0) }
            }
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard try Data(contentsOf: temporary) == data,
                (try? JSONSerialization.jsonObject(with: data)) != nil
            else { throw DispatchParticipationError.writeFailed }
            switch expectation {
            case .unchecked:
                let result = temporary.path.withCString { source in
                    url.path.withCString { destination in Darwin.rename(source, destination) }
                }
                guard result == 0 else { throw DispatchParticipationError.writeFailed }
            case .matching(let expected):
                guard try readBoundedRegularFile(url, allowMissing: true) == expected else {
                    throw DispatchParticipationError.concurrentChange
                }
                if let checkpointIndex {
                    try checkpoint?(.beforeAtomicSwap(checkpointIndex))
                }
                let flags = UInt32(expected == nil ? RENAME_EXCL : RENAME_SWAP)
                let result = temporary.path.withCString { source in
                    url.path.withCString { destination in
                        Darwin.renamex_np(source, destination, flags)
                    }
                }
                guard result == 0 else { throw DispatchParticipationError.concurrentChange }
                guard let expected else { return }
                let displaced: Data
                do {
                    guard let value = try readBoundedRegularFile(temporary) else {
                        throw DispatchParticipationError.rollbackFailed
                    }
                    displaced = value
                } catch {
                    removeTemporary = false
                    throw DispatchParticipationError.rollbackFailed
                }
                guard displaced != expected else { return }

                // The target changed after the last read. Restore that displaced
                // writer atomically only while our exact bytes still occupy it.
                removeTemporary = false
                do {
                    guard try readBoundedRegularFile(url, allowMissing: true) == data else {
                        throw DispatchParticipationError.rollbackFailed
                    }
                    if let checkpointIndex {
                        try checkpoint?(.beforeMismatchRestore(checkpointIndex))
                    }
                    let restoreResult = temporary.path.withCString { source in
                        url.path.withCString { destination in
                            Darwin.renamex_np(source, destination, UInt32(RENAME_SWAP))
                        }
                    }
                    guard restoreResult == 0 else {
                        throw DispatchParticipationError.rollbackFailed
                    }
                    if let checkpointIndex {
                        try checkpoint?(.afterMismatchRestore(checkpointIndex))
                    }
                    guard try readBoundedRegularFile(temporary) == data else {
                        throw DispatchParticipationError.rollbackFailed
                    }
                    removeTemporary = true
                } catch let error as DispatchParticipationError {
                    throw error
                } catch {
                    throw DispatchParticipationError.rollbackFailed
                }
                throw DispatchParticipationError.concurrentChange
            }
        } catch let error as DispatchParticipationError {
            throw error
        } catch {
            throw DispatchParticipationError.writeFailed
        }
    }

    private static func removeAtomicallyIfMatching(
        _ expected: Data,
        at url: URL,
        checkpointIndex: Int? = nil,
        checkpoint: ((Checkpoint) throws -> Void)? = nil
    ) throws {
        let displaced = url.deletingLastPathComponent().appendingPathComponent(
            ".camnext-dispatch-\(UUID().uuidString).remove"
        )
        var removeDisplaced = false
        defer {
            if removeDisplaced {
                displaced.path.withCString { _ = Darwin.unlink($0) }
            }
        }
        let moveResult = url.path.withCString { source in
            displaced.path.withCString { destination in
                Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
        }
        guard moveResult == 0 else { throw DispatchParticipationError.concurrentChange }
        do {
            if let checkpointIndex {
                try checkpoint?(.afterRemovalMove(checkpointIndex))
            }
            if try readBoundedRegularFile(displaced) == expected {
                removeDisplaced = true
                return
            }
        } catch {
            // Unknown or unreadable displaced content must be restored or kept.
        }
        let restoreResult = displaced.path.withCString { source in
            url.path.withCString { destination in
                Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
        }
        if restoreResult == 0 {
            throw DispatchParticipationError.concurrentChange
        }
        throw DispatchParticipationError.rollbackFailed
    }
}
