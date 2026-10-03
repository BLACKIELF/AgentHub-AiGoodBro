import Foundation

/// Lossless JSON numbers (including Int64 counters), arbitrary model keys and dimensions.
indirect enum TokenMonitorJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([Self])
    case object([String: Self])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Decimal.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([Self].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: Self].self))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    subscript(_ key: String) -> Self? {
        if case .object(let v) = self { return v[key] }
        return nil
    }
    var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    var array: [Self]? {
        if case .array(let v) = self { return v }
        return nil
    }
    var object: [String: Self]? {
        if case .object(let v) = self { return v }
        return nil
    }
    var double: Double? {
        if case .number(let v) = self { return NSDecimalNumber(decimal: v).doubleValue }
        return nil
    }

    /// Forbidden content is rejected, never copied into a diagnostic or cache.
    func validate(depth: Int = 0) throws {
        guard depth < 80 else { throw TokenMonitorFailure.invalidResponse }
        switch self {
        case .number(let v):
            guard !v.isNaN, v >= 0, NSDecimalNumber(decimal: v).doubleValue.isFinite else { throw TokenMonitorFailure.invalidNumber }
        case .string(let v):
            guard !v.contains("@") || v.range(of: #"(?i)[A-Z0-9._%+-]{1,64}@[A-Z0-9.-]{1,253}\.[A-Z]{2,63}"#, options: .regularExpression) == nil,
                v.range(of: #"(?i)\b(?:Bearer\s+\S+|sk-[A-Za-z0-9_-]{16,})"#, options: .regularExpression) == nil,
                !v.hasPrefix("/"), !v.hasPrefix("~/"), !v.contains(":\\"),
                !v.contains("file://"), !v.contains("\0")
            else { throw TokenMonitorFailure.unsafePayload }
        case .array(let v): try v.forEach { try $0.validate(depth: depth + 1) }
        case .object(let v):
            let forbidden: Set<String> = [
                "prompt", "prompts", "response", "responsetext", "prompttext", "messages", "accesstoken", "refreshtoken", "idtoken", "authorization", "apikey", "auth", "email",
                "accountemail", "canonicalpath", "homepath", "authpath", "cwd", "path", "filepath", "sessiontext", "text", "content", "body", "message", "transcript", "password",
                "cookie", "sessiontoken", "webhookurl",
            ]
            for (key, value) in v {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                // Original history contains a numeric message count, never message bodies.
                let isMessageCount =
                    normalized == "messages"
                    && value.double.map {
                        $0.isFinite && $0 >= 0 && $0.rounded() == $0
                    } == true
                guard !forbidden.contains(normalized) || isMessageCount else { throw TokenMonitorFailure.unsafePayload }
                try Self.string(key).validate(depth: depth + 1)
                try value.validate(depth: depth + 1)
            }
        default: break
        }
    }
}

enum TokenMonitorFailure: String, Error, Codable, Sendable {
    case missingBundle = "missing_bundle"
    case invalidSource = "invalid_source"
    case overlappingSource = "overlapping_source"
    case invalidRequest = "invalid_request"
    case invalidResponse = "invalid_response"
    case invalidNumber = "invalid_number"
    case unsafePayload = "unsafe_payload"
    case engineMismatch = "engine_mismatch"
    case requestMismatch = "request_mismatch"
    case outputTooLarge = "output_too_large"
    case inputTooLarge = "input_too_large"
    case timedOut = "timed_out"
    case cancelled
    case spawnFailed = "spawn_failed"
    case processFailed = "process_failed"
    case cleanupUnknown = "cleanup_unknown"
    case engineError = "engine_error"
    case limitsMappingUnavailable = "limits_mapping_unavailable"
}
enum StatisticsEngineChoice: String, Codable, CaseIterable, Sendable {
    case upstream, nativeLegacy, custom
    static let storageKey = "CodexManagerNext.statisticsEngine"
    static func stored(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .upstream
    }
}
enum TokenMonitorOperation: String, Codable, Sendable { case collectUsage, collectLimits, capabilities }
enum TokenMonitorCoverageStatus: String, Codable, Sendable { case known, partial, unknown }
struct TokenMonitorSource: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case agentLogs, managedAccount, custom }
    enum PathRole: String, Codable, Sendable { case userHome, codexHome, logRoot, customFile, configDirectory }
    enum Authority: String, Codable, Sendable { case upstream, custom }
    var id: String
    var providerId: String
    var kind: Kind
    var canonicalPath: String
    var pathRole: PathRole
    var accountId: String? = nil
    var toolId: String? = nil
    var authority: Authority = .upstream
    var enabled: Bool = true

    static func validated(_ sources: [Self], operation: TokenMonitorOperation? = nil) throws -> [Self] {
        guard sources.count <= 256, Set(sources.map(\.id)).count == sources.count else { throw TokenMonitorFailure.invalidSource }
        var accepted: [Self] = []
        for var source in sources {
            guard safeID(source.id), safeID(source.providerId), source.accountId.map(safeID) != false,
                source.toolId.map(safeID) != false,
                source.canonicalPath.hasPrefix("/"), !source.canonicalPath.contains("\0")
            else { throw TokenMonitorFailure.invalidSource }
            switch (source.kind, source.pathRole, source.authority) {
            case (.managedAccount, .codexHome, .upstream):
                guard source.providerId == "codex" else { throw TokenMonitorFailure.invalidSource }
            case (.managedAccount, .configDirectory, .upstream):
                guard source.providerId == "opencode", operation == .collectLimits, source.accountId != nil else {
                    throw TokenMonitorFailure.invalidSource
                }
            case (.agentLogs, .logRoot, .upstream), (.agentLogs, .userHome, .upstream): break
            case (.custom, .customFile, .custom): break
            default: throw TokenMonitorFailure.invalidSource
            }
            let url = URL(fileURLWithPath: source.canonicalPath).resolvingSymlinksInPath().standardizedFileURL
            guard url.path != "/", url.lastPathComponent != "auth.json" else { throw TokenMonitorFailure.invalidSource }
            source.canonicalPath = url.path
            // Different tools can share one approved userHome while scanning
            // different logs. The engine knows each provider's actual scan
            // scope and reports aliases/overlap as excluded before collecting.
            accepted.append(source)
        }
        return accepted
    }
    static func safeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95, 46].contains($0)
            }
    }
}
struct TokenMonitorCustomSource: Codable, Sendable {
    var sourceId: String
    var providerId: String
    var toolId: String
    var accountId: String?
    var period: String
    var date: String?
    var tokens: Decimal?
    var cost: Decimal?
    var currency: String?
    var coverage: TokenMonitorCoverageStatus
    var provenance: String
    var overlapsSourceIds: [String]
}
struct TokenMonitorRequest: Codable, Sendable {
    var schemaVersion = 1
    var requestId = UUID().uuidString
    var operation: TokenMonitorOperation
    var now = ISO8601DateFormatter().string(from: Date())
    var timezone: String
    var cacheDirectory: String
    var sources: [TokenMonitorSource]
    struct Options: Codable, Sendable {
        var timeoutMs = 15_000
        var allowPriceNetwork = false
        var allowSelfSync = false
        var allowCredentialRefresh = false
        var includeLiveCodexAccount = false
    }
    var options = Options()
    var customSources: [TokenMonitorCustomSource]? = nil
    func validated() throws -> Self {
        guard schemaVersion == 1, TokenMonitorSource.safeID(requestId), TimeZone(identifier: timezone) != nil,
            TokenMonitorResponse.timestamp(now) != nil,
            cacheDirectory.hasPrefix("/"), !cacheDirectory.contains("\0"),
            (1...(operation == .collectUsage ? 180_000 : 60_000)).contains(options.timeoutMs),
            !options.allowPriceNetwork, !options.allowSelfSync,
            !options.allowCredentialRefresh, !options.includeLiveCodexAccount
        else { throw TokenMonitorFailure.invalidRequest }
        guard (customSources?.count ?? 0) <= 256 else { throw TokenMonitorFailure.inputTooLarge }
        var result = self
        result.sources = try TokenMonitorSource.validated(sources, operation: operation)
        for custom in customSources ?? [] {
            guard TokenMonitorSource.safeID(custom.sourceId), TokenMonitorSource.safeID(custom.providerId),
                TokenMonitorSource.safeID(custom.toolId), custom.accountId.map(TokenMonitorSource.safeID) != false,
                ["today", "month", "allTime"].contains(custom.period), ["manual", "legacy"].contains(custom.provenance),
                custom.overlapsSourceIds.allSatisfy(TokenMonitorSource.safeID),
                custom.date.map(TokenMonitorResponse.validDate) != false,
                custom.currency.map({ $0.utf8.count == 3 && $0.utf8.allSatisfy { (65...90).contains($0) } }) != false,
                custom.tokens.map({ !$0.isNaN && $0 >= 0 }) != false,
                custom.cost.map({ !$0.isNaN && $0 >= 0 }) != false,
                let source = result.sources.first(where: { $0.id == custom.sourceId }), source.authority == .custom
            else { throw TokenMonitorFailure.invalidSource }
            // Legacy records have no nonoverlap proof: only exclusive custom mode is safe.
            guard !result.sources.contains(where: { $0.enabled && $0.authority == .upstream }) else { throw TokenMonitorFailure.overlappingSource }
        }
        return result
    }
}
struct TokenMonitorResponse: Codable, Sendable {
    struct Engine: Codable, Sendable {
        var repository: String
        var commit: String
        var version: String
    }
    enum Status: String, Codable, Sendable { case ok, partial, error }
    struct Source: Codable, Sendable {
        enum Status: String, Codable, Sendable { case ok, unavailable, error, excluded }
        var id: String
        var providerId: String
        var status: Status
        var coverage: TokenMonitorCoverageStatus
        var reasonCode: String?
    }
    struct Coverage: Codable, Sendable {
        struct Entry: Codable, Sendable {
            var sourceId: String
            var providerId: String
            var toolId: String?
            var accountId: String?
            var date: String
            var metric: String
            var status: TokenMonitorCoverageStatus
        }
        struct Day: Codable, Sendable {
            var date: String
            var status: TokenMonitorCoverageStatus
        }
        var entries: [Entry]
        var days: [Day]
        var cost: TokenMonitorCoverageStatus
    }
    struct Diagnostic: Codable, Sendable {
        var code: String
        var sourceId: String?
        var retryable: Bool
    }
    var schemaVersion: Int
    var requestId: String
    var operation: TokenMonitorOperation?
    var engine: Engine
    var collectedAt: String
    var timezone: String
    var status: Status
    var sources: [Source]
    var payload: TokenMonitorJSON
    var coverage: Coverage
    var errors: [Diagnostic]
    static let commit = "dcccfb01557e2786888fd5479552f392ac6c0d32"

    struct CoverageIndex {
        private struct Key: Hashable {
            let sourceID: String
            let date: String
            let metric: String
        }

        private let sourceStatuses: [String: Source.Status]
        private let knownByKey: [Key: Bool]

        init(response: TokenMonitorResponse) {
            sourceStatuses = response.sources.reduce(into: [:]) { result, source in
                if result[source.id] == nil { result[source.id] = source.status }
            }
            knownByKey = response.coverage.entries.reduce(into: [:]) { result, entry in
                let key = Key(sourceID: entry.sourceId, date: entry.date, metric: entry.metric)
                result[key] = (result[key] ?? true) && entry.status == .known
            }
        }

        func metricCoverage(sourceIDs: [String], date: String, metric: String) -> TokenMonitorCoverageStatus {
            var hasKnown = false
            var hasUnknown = false
            for sourceID in sourceIDs {
                guard sourceStatuses[sourceID] != .excluded else { continue }
                let key = Key(sourceID: sourceID, date: date, metric: metric)
                if sourceStatuses[sourceID] == .ok, knownByKey[key] == true {
                    hasKnown = true
                } else {
                    hasUnknown = true
                }
            }
            if hasUnknown { return hasKnown ? .partial : .unknown }
            return hasKnown ? .known : .unknown
        }
    }

    func metricCoverage(sourceIDs: [String], date: String, metric: String) -> TokenMonitorCoverageStatus {
        CoverageIndex(response: self).metricCoverage(sourceIDs: sourceIDs, date: date, metric: metric)
    }
    static func decode(_ data: Data, request: TokenMonitorRequest) throws -> Self {
        guard data.count <= TokenMonitorEngine.maximumOutputBytes, String(data: data, encoding: .utf8) != nil else { throw TokenMonitorFailure.invalidResponse }
        var response: Self
        do { response = try JSONDecoder().decode(Self.self, from: data) } catch { throw TokenMonitorFailure.invalidResponse }
        guard response.schemaVersion == 1 else { throw TokenMonitorFailure.invalidResponse }
        guard response.requestId == request.requestId, response.operation == nil || response.operation == request.operation else { throw TokenMonitorFailure.requestMismatch }
        guard response.engine.repository == "Javis603/token-monitor", response.engine.commit == commit,
            TokenMonitorSource.safeID(response.engine.version)
        else { throw TokenMonitorFailure.engineMismatch }
        guard response.timezone == request.timezone, timestamp(response.collectedAt) != nil else { throw TokenMonitorFailure.invalidResponse }
        let expected = Dictionary(uniqueKeysWithValues: request.sources.map { ($0.id, $0) })
        guard Set(response.sources.map(\.id)).count == response.sources.count,
            Set(response.sources.map(\.id)) == Set(expected.keys)
        else { throw TokenMonitorFailure.invalidSource }
        for source in response.sources {
            guard expected[source.id]?.providerId == source.providerId else { throw TokenMonitorFailure.invalidSource }
        }
        for entry in response.coverage.entries {
            guard let source = expected[entry.sourceId], source.providerId == entry.providerId,
                entry.accountId == nil || entry.accountId == source.accountId,
                entry.toolId == nil || entry.toolId == source.toolId,
                ["tokens", "cost", "quota"].contains(entry.metric), validDate(entry.date)
            else { throw TokenMonitorFailure.invalidResponse }
        }
        guard response.coverage.days.allSatisfy({ validDate($0.date) }) else { throw TokenMonitorFailure.invalidResponse }
        // Never propagate arbitrary bridge diagnostics. Fixed native category only.
        for i in response.sources.indices where response.sources[i].reasonCode != nil {
            response.sources[i].reasonCode = TokenMonitorFailure.engineError.rawValue
        }
        for i in response.errors.indices {
            guard response.errors[i].sourceId == nil || expected[response.errors[i].sourceId!] != nil else { throw TokenMonitorFailure.invalidSource }
            response.errors[i].code = TokenMonitorFailure.engineError.rawValue
        }
        try response.payload.validate()
        if response.status != .error {
            switch request.operation {
            case .collectUsage:
                guard response.payload["usage"] != nil, response.payload["history"] != nil, response.payload["aggregate"] != nil else { throw TokenMonitorFailure.invalidResponse }
            case .collectLimits: guard response.payload["limits"] != nil else { throw TokenMonitorFailure.invalidResponse }
            case .capabilities: break
            }
        }
        // Compatibility summary cannot overstate authoritative per-source entries.
        let excluded = Set(response.sources.filter { $0.status == .excluded }.map(\.id))
        let included = request.sources.filter { $0.enabled && !excluded.contains($0.id) }.map(\.id)
        let includedEntries = response.coverage.entries.filter { included.contains($0.sourceId) }
        let coverageIndex = CoverageIndex(response: response)
        for i in response.coverage.days.indices {
            let date = response.coverage.days[i].date
            response.coverage.days[i].status = coverageIndex.metricCoverage(sourceIDs: included, date: date, metric: "tokens")
        }
        if request.operation != .capabilities {
            let dates = Set(response.coverage.days.map(\.date)).union(includedEntries.map(\.date))
            response.coverage.cost =
                !dates.isEmpty && dates.allSatisfy({ coverageIndex.metricCoverage(sourceIDs: included, date: $0, metric: "cost") == .known }) ? .known : .unknown
            if response.status == .ok
                && (included.isEmpty || response.sources.contains { included.contains($0.id) && ($0.status != .ok || $0.coverage != .known) }
                    || includedEntries.contains { $0.status != .known }
                    || response.coverage.days.contains { $0.status != .known }
                    || (request.operation == .collectUsage && response.coverage.cost != .known))
            {
                response.status = .partial
            }
        }
        return response
    }
    static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
    static func validDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
    }
}
struct TokenMonitorEngineState: Sendable {
    enum Phase: String, Sendable { case idle, loading, ready, partial, failed, stopped, legacy, custom }
    var phase: Phase
    let lastGood: TokenMonitorResponse?
    let dashboardJSON: String?
    var failureCode: TokenMonitorFailure?

    /// Prepare once on the collection queue; view updates reuse the same encoded snapshot.
    init(phase: Phase = .idle, lastGood: TokenMonitorResponse? = nil, failureCode: TokenMonitorFailure? = nil) {
        self.phase = phase
        self.lastGood = lastGood
        self.failureCode = failureCode
        if let lastGood {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            dashboardJSON = (try? encoder.encode(lastGood)).flatMap { String(data: $0, encoding: .utf8) }
        } else {
            dashboardJSON = nil
        }
    }
    var lastGoodAt: String? { lastGood?.collectedAt }
    var isStale: Bool { lastGood != nil && phase != .ready && phase != .partial }
}

/// Adapter for the unique source/account target in the confirmed upstream limits schema.
struct TokenMonitorCodexLimits: Sendable {
    struct Window: Sendable {
        let usedPercent: Double
        let minutes: Int
        let resetsAt: Date?
    }
    let fiveHour: Window?
    let sevenDay: Window?
    let monthly: Window?
    let limitID: String
    let original: TokenMonitorJSON

    /// Binding belongs to the target, not provider labels. Preserve the original summary unchanged.
    static func select(_ response: TokenMonitorResponse, sourceID: String, accountID: String? = nil) -> TokenMonitorJSON? {
        let expectedAccountID = accountID ?? sourceID
        guard response.status != .error,
            response.sources.filter({ $0.id == sourceID && $0.providerId == "codex" && $0.status == .ok }).count == 1,
            let targets = response.payload["limits"]?["targets"]?.array
        else { return nil }
        let matching = targets.filter { $0["sourceId"]?.string == sourceID }
        guard matching.count == 1, let target = matching.first,
            target["providerId"]?.string == "codex", target["accountId"]?.string == expectedAccountID,
            let providers = target["snapshot"]?["providers"]?.array
        else { return nil }
        let codex = providers.filter { $0["provider"]?.string == "codex" }
        guard codex.count == 1 else { return nil }
        return codex.first
    }

    init(provider: TokenMonitorJSON, sourceID: String, accountID: String, response: TokenMonitorResponse) throws {
        guard response.sources.contains(where: { $0.id == sourceID && $0.providerId == "codex" && $0.status == .ok }),
            Self.select(response, sourceID: sourceID, accountID: accountID) == provider,
            provider["provider"]?.string == "codex", provider["status"]?.string == "ok",
            let windows = provider["windows"]?.array, !windows.isEmpty
        else { throw TokenMonitorFailure.invalidSource }
        var five: Window?
        var seven: Window?
        var month: Window?
        let general = windows.filter { $0["limitId"]?.string == "codex" && $0["additional"] != .bool(true) }
        guard !general.isEmpty else { throw TokenMonitorFailure.limitsMappingUnavailable }
        for window in general {
            let used = window["usedPercent"]?.double
            let remaining = window["remainingPercent"]?.double ?? window["remainingPct"]?.double
            guard let value = used ?? remaining.map({ 100 - $0 }), value.isFinite, (0...100).contains(value),
                used == nil || remaining == nil || abs(value + remaining! - 100) < 0.000_001,
                let duration = window["windowMinutes"]?.double, duration.isFinite,
                let minutes = Int(exactly: duration), minutes > 0
            else { throw TokenMonitorFailure.invalidNumber }
            let reset: Date?
            if let text = window["resetsAt"]?.string {
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: text) {
                    reset = date
                } else {
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    guard let date = formatter.date(from: text) else { throw TokenMonitorFailure.invalidResponse }
                    reset = date
                }
            } else if let seconds = window["resetsAt"]?.double {
                // Raw Codex epochs are seconds. Do not guess milliseconds by magnitude.
                guard seconds >= 0, seconds < 253_402_300_800 else { throw TokenMonitorFailure.invalidNumber }
                reset = Date(timeIntervalSince1970: seconds)
            } else if window["resetsAt"] == nil || window["resetsAt"] == .null {
                reset = nil
            } else {
                throw TokenMonitorFailure.invalidResponse
            }
            if let kind = window["kind"]?.string {
                let expected = minutes == 300 ? "session" : minutes == 10_080 ? "weekly" : "billing"
                guard kind == expected else { throw TokenMonitorFailure.limitsMappingUnavailable }
            }
            let mapped = Window(usedPercent: value, minutes: minutes, resetsAt: reset)
            switch minutes {
            case 300:
                guard five == nil else { throw TokenMonitorFailure.invalidResponse }
                five = mapped
            case 10_080:
                guard seven == nil else { throw TokenMonitorFailure.invalidResponse }
                seven = mapped
            case (28 * 1440)...(31 * 1440):
                guard month == nil else { throw TokenMonitorFailure.invalidResponse }
                month = mapped
            default: throw TokenMonitorFailure.limitsMappingUnavailable
            }
        }
        fiveHour = five
        sevenDay = seven
        monthly = month
        limitID = "codex"
        original = provider
        // Credits (including unlimited balance) never manufacture a missing quota window.
    }
}

/// Main-thread value gate shared by refresh replacement, source changes and stop.
struct TokenMonitorGeneration: Sendable {
    private(set) var value: UInt64 = 0
    mutating func invalidate() { value &+= 1 }
    func accepts(_ ticket: UInt64) -> Bool { ticket == value }
}

enum TokenMonitorQuotaRoute: Equatable {
    case membershipRPC, legacyRPC, engine
    static func select(refreshingMembership: Bool, choice: StatisticsEngineChoice) -> Self {
        if refreshingMembership { return .membershipRPC }
        return .engine
    }
}
