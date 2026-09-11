import Foundation

/// Per-model CLI evidence and independent free-source facts.
///
/// A passing test for one model never makes the rest of that provider
/// dispatchable. Free-source dates are a separate fact from test status:
/// missing `startsOn`/`endsOn` display as 未注明 / not stated; no invented end date.
enum LocalCLIModelTestStatus: String, Codable, Equatable {
    case untested
    case passed
    case invalid
}

enum LocalCLIFreeSourceKind: String, Codable, Equatable {
    case official
    case userConfirmed
}

enum LocalCLIFreeWindowState: String, Equatable {
    case unknown
    case upcoming
    case active
    case expired
}

enum LocalCLIModelDispatchReason: String, Equatable {
    case eligible
    case untested
    case identityMismatch
    case modelMismatch
    case environmentMismatch
    case expired
    case futureTest
    case invalidMinimumReturn
    case invalidEvidence
}

/// Civil date or date-time without inventing a timezone.
/// Absolute ISO-8601 values with an offset are stored separately.
struct LocalCLICivilInstant: Equatable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int?
    let minute: Int?

    var hasClock: Bool { hour != nil && minute != nil }

    func date(in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour ?? 0
        components.minute = minute ?? 0
        components.second = 0
        return calendar.date(from: components)
    }

    func endOfDay(in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 23
        components.minute = 59
        components.second = 59
        return calendar.date(from: components)
    }

    var displayText: String {
        let y = String(format: "%04d", year)
        let m = String(format: "%02d", month)
        let d = String(format: "%02d", day)
        guard let hour, let minute else { return "\(y)-\(m)-\(d)" }
        return "\(y)-\(m)-\(d) \(String(format: "%02d", hour)):\(String(format: "%02d", minute))"
    }
}

enum LocalCLIOptionalInstant: Equatable {
    case unknown
    case civil(LocalCLICivilInstant)
    case absolute(Date)

    func date(in timeZone: TimeZone, endOfDayIfDateOnly: Bool) -> Date? {
        switch self {
        case .unknown:
            return nil
        case .civil(let civil):
            if endOfDayIfDateOnly, !civil.hasClock { return civil.endOfDay(in: timeZone) }
            return civil.date(in: timeZone)
        case .absolute(let date):
            return date.timeIntervalSince1970.isFinite ? date : nil
        }
    }

    var displayText: String? {
        switch self {
        case .unknown:
            return nil
        case .civil(let civil):
            return civil.displayText
        case .absolute(let date):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: date)
        }
    }

    /// Civil values have no timezone in the source statement.
    var timezoneUnstated: Bool {
        switch self {
        case .civil: true
        case .unknown, .absolute: false
        }
    }
}

struct LocalCLICurrentBinding: Equatable {
    let provider: LocalCLIKind
    let modelID: String
    let environmentFingerprint: String
    let accountFingerprint: String
    var cliVersion: String? = nil
    var executableHash: String? = nil
}

struct LocalCLIModelTestEvidence: Equatable, Identifiable {
    let provider: LocalCLIKind
    let modelID: String
    let requestedModel: String
    let observedActualModel: String
    let cliVersion: String
    let executableHash: String
    let environmentFingerprint: String
    let accountFingerprint: String
    let matched: Bool
    let toolCalls: Int
    let exitCode: Int
    let testedAt: Date
    let validUntil: Date
    let recordedStatus: LocalCLIModelTestStatus

    var id: String {
        "\(provider.rawValue)|\(modelID)|\(accountFingerprint)|\(testedAt.timeIntervalSince1970)"
    }
}

struct LocalCLIFreeFact: Equatable, Identifiable {
    let provider: LocalCLIKind
    let modelIDs: [String]
    let label: String
    let source: LocalCLIFreeSourceKind
    let sourceURL: URL?
    let confirmedOn: LocalCLICivilInstant
    let startsOn: LocalCLIOptionalInstant
    let endsOn: LocalCLIOptionalInstant
    let sortIndex: Int

    var id: String { "\(provider.rawValue)|\(modelIDs.joined(separator: ","))|\(sortIndex)" }

    var primaryModelID: String { modelIDs.first ?? "" }

    func covers(_ modelID: String) -> Bool { modelIDs.contains(modelID) }
}

struct LocalCLIModelAvailabilitySnapshot: Equatable {
    enum Origin: Equatable {
        case missing
        case loaded
        case rejected(String)
    }

    var evidence: [LocalCLIModelTestEvidence]
    var freeFacts: [LocalCLIFreeFact]
    var origin: Origin

    static let empty = LocalCLIModelAvailabilitySnapshot(evidence: [], freeFacts: [], origin: .missing)

    var diskAccepted: Bool {
        switch origin {
        case .missing, .loaded: true
        case .rejected: false
        }
    }
}

enum LocalCLIModelAvailabilityLimits {
    static let schemaVersion = 1
    static let maximumFileBytes = 64 * 1_024
    static let maximumEvidence = 256
    static let maximumFreeFacts = 64
    static let futureSkew: TimeInterval = 300
    static let fileName = "model-availability-v1.json"

    static let publicSupportHosts: Set<String> = [
        "zcode.z.ai",
        "opencode.ai",
        "docs.opencode.ai",
    ]
}

enum LocalCLIModelEvidenceContract {
    static func boundedToken(_ value: String, maximumUTF8Bytes: Int) -> String? {
        LocalCLIQuotaPresentation.boundedLabel(value, maximumUTF8Bytes: maximumUTF8Bytes)
    }

    static func fingerprint(_ value: String) -> String? {
        guard let token = boundedToken(value, maximumUTF8Bytes: 128) else { return nil }
        guard token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) })
        else { return nil }
        guard !token.contains("@"), !token.lowercased().contains("example.invalid") else { return nil }
        return token
    }

    static func executableHash(_ value: String) -> String? {
        guard let token = boundedToken(value, maximumUTF8Bytes: 80) else { return nil }
        let hex = token.hasPrefix("sha256:") ? String(token.dropFirst(7)) : token
        guard hex.count == 64, hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) })
        else { return nil }
        return "sha256:" + hex
    }

    static func modelID(_ value: String) -> String? {
        guard let token = boundedToken(value, maximumUTF8Bytes: 128) else { return nil }
        guard !token.contains("@"), !token.contains("/") || token.allSatisfy({ $0.isASCII }) else { return nil }
        return token
    }

    static func cliVersion(_ value: String) -> String? {
        boundedToken(value, maximumUTF8Bytes: 64)
    }

    static func publicSupportURL(_ raw: String?) -> URL?? {
        guard let raw else { return .some(nil) }
        guard let token = boundedToken(raw, maximumUTF8Bytes: 256) else { return nil }
        guard let url = URL(string: token), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        guard parts.scheme == "https", let host = parts.host,
            LocalCLIModelAvailabilityLimits.publicSupportHosts.contains(host),
            parts.user == nil, parts.password == nil, parts.port == nil,
            parts.query == nil, parts.fragment == nil
        else { return nil }
        return url
    }

    static func calendarDay(_ value: LocalCLICivilInstant) -> Bool {
        (2020...2100).contains(value.year) && (1...12).contains(value.month) && (1...31).contains(value.day)
            && (value.hour.map { (0...23).contains($0) } ?? true)
            && (value.minute.map { (0...59).contains($0) } ?? true)
            && value.hour == nil && value.minute == nil
    }

    static func resolvedStatus(
        _ evidence: LocalCLIModelTestEvidence,
        now: Date
    ) -> LocalCLIModelTestStatus {
        switch evidence.recordedStatus {
        case .untested:
            return .untested
        case .invalid:
            return .invalid
        case .passed:
            if !minimumReturnHolds(evidence) { return .invalid }
            if evidence.testedAt.timeIntervalSince(now) > LocalCLIModelAvailabilityLimits.futureSkew { return .invalid }
            if now.timeIntervalSince(evidence.validUntil) > 0 { return .invalid }
            if evidence.validUntil < evidence.testedAt { return .invalid }
            return .passed
        }
    }

    static func minimumReturnHolds(_ evidence: LocalCLIModelTestEvidence) -> Bool {
        evidence.matched
            && evidence.toolCalls == 0
            && evidence.exitCode == 0
            && evidence.requestedModel == evidence.modelID
            && evidence.observedActualModel == evidence.modelID
            && evidence.testedAt.timeIntervalSince1970.isFinite
            && evidence.validUntil.timeIntervalSince1970.isFinite
    }
}

enum LocalCLICivilInstantParsing {
    static func calendarDay(_ raw: String) -> LocalCLICivilInstant? {
        let parsed = parse(raw)
        guard case .civil(let instant) = parsed, !instant.hasClock, LocalCLIModelEvidenceContract.calendarDay(instant)
        else { return nil }
        return instant
    }

    static func optionalInstant(_ raw: String?) -> LocalCLIOptionalInstant? {
        guard let raw else { return .unknown }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .unknown }
        return parse(trimmed)
    }

    static func parse(_ raw: String) -> LocalCLIOptionalInstant? {
        if hasExplicitTimeZone(raw) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return .absolute(date) }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: raw) else { return nil }
            return .absolute(date)
        }
        guard let civil = parseCivil(raw) else { return nil }
        return .civil(civil)
    }

    static func parseCivil(_ raw: String) -> LocalCLICivilInstant? {
        let pieces = raw.split(separator: "T", omittingEmptySubsequences: false)
        guard let datePart = pieces.first, (1...2).contains(pieces.count) else { return nil }
        let dateBits = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard dateBits.count == 3,
            let year = Int(dateBits[0]), dateBits[0].count == 4,
            let month = Int(dateBits[1]), dateBits[1].count == 2,
            let day = Int(dateBits[2]), dateBits[2].count == 2,
            (2020...2100).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        if pieces.count == 1 {
            return LocalCLICivilInstant(year: year, month: month, day: day, hour: nil, minute: nil)
        }
        let timeBits = pieces[1].split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(timeBits.count),
            let hour = Int(timeBits[0]), timeBits[0].count == 2,
            let minute = Int(timeBits[1]), timeBits[1].count == 2,
            (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        if timeBits.count == 3 {
            let secondField = timeBits[2]
            guard let second = Int(secondField.split(separator: ".").first ?? Substring()),
                (0...59).contains(second)
            else { return nil }
        }
        return LocalCLICivilInstant(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    private static func hasExplicitTimeZone(_ raw: String) -> Bool {
        if raw.contains("Z") || raw.contains("z") { return true }
        guard let t = raw.firstIndex(of: "T") else { return false }
        let clock = raw[raw.index(after: t)...]
        return clock.contains("+") || clock.dropFirst(8).contains("-")
    }
}

enum LocalCLIFreeWindow {
    static func state(
        _ fact: LocalCLIFreeFact,
        now: Date,
        timeZone: TimeZone
    ) -> LocalCLIFreeWindowState {
        if let start = fact.startsOn.date(in: timeZone, endOfDayIfDateOnly: false), start > now {
            return .upcoming
        }
        switch fact.endsOn {
        case .unknown:
            if case .unknown = fact.startsOn { return .unknown }
            return .active
        case .civil, .absolute:
            guard let end = fact.endsOn.date(in: timeZone, endOfDayIfDateOnly: true) else { return .unknown }
            return end < now ? .expired : .active
        }
    }
}

enum LocalCLIModelDispatch {
    /// Only the requested model, current environment, and current anonymous
    /// account fingerprint may pass. One model never unlocks a provider.
    static func reason(
        snapshot: LocalCLIModelAvailabilitySnapshot,
        binding: LocalCLICurrentBinding,
        now: Date
    ) -> LocalCLIModelDispatchReason {
        guard snapshot.diskAccepted else { return .invalidEvidence }
        guard let model = LocalCLIModelEvidenceContract.modelID(binding.modelID),
            let account = LocalCLIModelEvidenceContract.fingerprint(binding.accountFingerprint),
            let environment = LocalCLIModelEvidenceContract.fingerprint(binding.environmentFingerprint)
        else { return .invalidEvidence }
        // Grok admits only exact grok-4.6-build. Unverified aliases stay untested.
        guard LocalCLIDocumentedModelAliases.admittedModelID(provider: binding.provider, requested: model) != nil
        else { return .untested }

        let related = snapshot.evidence.filter {
            $0.provider == binding.provider && $0.modelID == model
        }
        if related.isEmpty { return .untested }

        let sameAccount = related.filter { $0.accountFingerprint == account }
        if sameAccount.isEmpty { return .identityMismatch }

        let sameEnvironment = sameAccount.filter { $0.environmentFingerprint == environment }
        if sameEnvironment.isEmpty { return .environmentMismatch }

        let latest = sameEnvironment.max(by: { $0.testedAt < $1.testedAt })
        guard let latest else { return .untested }

        if latest.testedAt.timeIntervalSince(now) > LocalCLIModelAvailabilityLimits.futureSkew {
            return .futureTest
        }
        if now > latest.validUntil { return .expired }
        if !LocalCLIModelEvidenceContract.minimumReturnHolds(latest) { return .invalidMinimumReturn }
        if LocalCLIModelEvidenceContract.resolvedStatus(latest, now: now) != .passed { return .invalidEvidence }
        if let expectedHash = binding.executableHash.flatMap(LocalCLIModelEvidenceContract.executableHash),
            expectedHash != latest.executableHash
        {
            return .environmentMismatch
        }
        if let expectedVersion = binding.cliVersion.flatMap(LocalCLIModelEvidenceContract.cliVersion),
            expectedVersion != latest.cliVersion
        {
            return .environmentMismatch
        }
        return .eligible
    }

    static func allows(
        snapshot: LocalCLIModelAvailabilitySnapshot,
        binding: LocalCLICurrentBinding,
        now: Date
    ) -> Bool {
        reason(snapshot: snapshot, binding: binding, now: now) == .eligible
    }

    /// Informational only: never used as a provider-wide dispatch grant.
    static func passingModelIDs(
        snapshot: LocalCLIModelAvailabilitySnapshot,
        provider: LocalCLIKind,
        accountFingerprint: String,
        environmentFingerprint: String,
        now: Date
    ) -> [String] {
        guard snapshot.diskAccepted,
            let account = LocalCLIModelEvidenceContract.fingerprint(accountFingerprint),
            let environment = LocalCLIModelEvidenceContract.fingerprint(environmentFingerprint)
        else { return [] }
        let ids = snapshot.evidence.compactMap { evidence -> String? in
            guard evidence.provider == provider,
                evidence.accountFingerprint == account,
                evidence.environmentFingerprint == environment,
                LocalCLIDocumentedModelAliases.admittedModelID(provider: provider, requested: evidence.modelID) != nil,
                LocalCLIModelEvidenceContract.resolvedStatus(evidence, now: now) == .passed
            else { return nil }
            return evidence.modelID
        }
        return Array(Set(ids)).sorted()
    }
}

/// Documented free-source labels and dates. These are not dispatch grants
/// and do not encode private remaining quota.
enum LocalCLIDocumentedFreeFacts {
    static let confirmedOn = LocalCLICivilInstant(year: 2026, month: 9, day: 11, hour: nil, minute: nil)

    static let workBuddy: [LocalCLIFreeFact] = [
        fact(
            provider: .workBuddy,
            modelIDs: ["deepseek-v4.1-flash"],
            label: "DeepSeek 4 Flash",
            source: .userConfirmed,
            sortIndex: 0
        ),
        fact(
            provider: .workBuddy,
            modelIDs: ["hy4-preview-f"],
            label: "HY4",
            source: .userConfirmed,
            sortIndex: 1
        ),
        fact(
            provider: .workBuddy,
            modelIDs: ["hy3"],
            label: "HY3",
            source: .userConfirmed,
            sortIndex: 2
        ),
    ]

    static let openCodeMimoFree = fact(
        provider: .openCode,
        modelIDs: ["mimo-v2.5-free"],
        label: "mimo-v2.5-free",
        source: .official,
        sortIndex: 0
    )

    /// Official trial label and deadline as stated (confirmedOn 2026-09-11,
    /// ends 2026-09-15 23:59; timezone not given in the source statement).
    /// Exhausted refresh is an account-local quota fact and is not stored
    /// here; catalog facts never mark the model currently requestable.
    static let zcodeGLM53Flash = LocalCLIFreeFact(
        provider: .zcode,
        modelIDs: ["glm-5.3", "glm-5.3-flash"],
        label: "GLM-5.3/Flash",
        source: .official,
        sourceURL: URL(string: "https://zcode.z.ai"),
        confirmedOn: confirmedOn,
        startsOn: .unknown,
        endsOn: .civil(LocalCLICivilInstant(year: 2026, month: 9, day: 15, hour: 23, minute: 59)),
        sortIndex: 0
    )

    static let all: [LocalCLIFreeFact] = workBuddy + [openCodeMimoFree, zcodeGLM53Flash]

    static func facts(for provider: LocalCLIKind) -> [LocalCLIFreeFact] {
        all.filter { $0.provider == provider }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Catalog facts are not dispatch grants, login recovery, or per-model
    /// availability evidence. Exhausted same-day refresh is account-local
    /// and is not stored here.
    private static func fact(
        provider: LocalCLIKind,
        modelIDs: [String],
        label: String,
        source: LocalCLIFreeSourceKind,
        sortIndex: Int
    ) -> LocalCLIFreeFact {
        LocalCLIFreeFact(
            provider: provider,
            modelIDs: modelIDs,
            label: label,
            source: source,
            sourceURL: nil,
            confirmedOn: confirmedOn,
            startsOn: .unknown,
            endsOn: .unknown,
            sortIndex: sortIndex
        )
    }
}

/// Official / event-backed model IDs only. C 0911v8 found no official entry
/// mapping `grok-4.6` → `grok-4.6-build`; this module does not invent one
/// or any prefix wildcard. `grok-4.5` stays untested.
enum LocalCLIDocumentedModelAliases {
    static let grokCanonical = "grok-4.6-build"

    static func admittedModelID(provider: LocalCLIKind, requested: String) -> String? {
        guard let model = LocalCLIModelEvidenceContract.modelID(requested) else { return nil }
        switch provider {
        case .grok:
            return model == grokCanonical ? model : nil
        default:
            return model
        }
    }

    static func remapsGrok46Alias(_: String) -> Bool {
        false
    }
}

struct LocalCLIModelAvailabilityRow: Equatable, Identifiable {
    let id: String
    let provider: LocalCLIKind
    let modelID: String
    let freeLabel: String?
    let originalFreeWord: String?
    let sourceKind: LocalCLIFreeSourceKind?
    let sourceURL: URL?
    let confirmedOn: LocalCLICivilInstant?
    let startsOn: LocalCLIOptionalInstant
    let deadline: LocalCLIOptionalInstant
    let window: LocalCLIFreeWindowState
    let testStatus: LocalCLIModelTestStatus
    let testedAt: Date?
    let dispatchEligible: Bool
}

enum LocalCLIModelAvailabilityPresentation {
    static func rows(
        snapshot: LocalCLIModelAvailabilitySnapshot,
        provider: LocalCLIKind,
        binding: LocalCLICurrentBinding?,
        now: Date,
        timeZone: TimeZone,
        includeDocumentedFreeFacts: Bool = true
    ) -> [LocalCLIModelAvailabilityRow] {
        var facts = snapshot.diskAccepted ? snapshot.freeFacts.filter { $0.provider == provider } : []
        if includeDocumentedFreeFacts {
            for documented in LocalCLIDocumentedFreeFacts.facts(for: provider) {
                let covered = Set(facts.flatMap(\.modelIDs))
                if documented.modelIDs.contains(where: { covered.contains($0) }) { continue }
                facts.append(documented)
            }
        }
        facts.sort { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.primaryModelID < rhs.primaryModelID
        }

        var modelIDs: [String] = []
        for fact in facts {
            for modelID in fact.modelIDs where !modelIDs.contains(modelID) {
                modelIDs.append(modelID)
            }
        }
        let evidence = relevantEvidence(snapshot: snapshot, provider: provider, binding: binding)
        for item in evidence where !modelIDs.contains(item.modelID) {
            modelIDs.append(item.modelID)
        }

        return modelIDs.map { modelID in
            let fact = facts.first { $0.covers(modelID) }
            let match = evidence.filter { $0.modelID == modelID }.max(by: { $0.testedAt < $1.testedAt })
            let status = match.map { LocalCLIModelEvidenceContract.resolvedStatus($0, now: now) } ?? .untested
            let eligible: Bool
            if let binding, binding.provider == provider, binding.modelID == modelID {
                eligible = LocalCLIModelDispatch.allows(snapshot: snapshot, binding: binding, now: now)
            } else {
                eligible = false
            }
            let original: String?
            if let label = fact?.label {
                original = label
            } else if modelID.lowercased().contains("free") {
                original = modelID
            } else {
                original = nil
            }
            return LocalCLIModelAvailabilityRow(
                id: "\(provider.rawValue)|\(modelID)",
                provider: provider,
                modelID: modelID,
                freeLabel: fact?.label,
                originalFreeWord: original,
                sourceKind: fact?.source,
                sourceURL: fact?.sourceURL,
                confirmedOn: fact?.confirmedOn,
                startsOn: fact?.startsOn ?? .unknown,
                deadline: fact?.endsOn ?? .unknown,
                window: fact.map { LocalCLIFreeWindow.state($0, now: now, timeZone: timeZone) } ?? .unknown,
                testStatus: status,
                testedAt: match?.testedAt,
                dispatchEligible: eligible
            )
        }
    }

    static func heading(_ language: WidgetLanguage) -> String {
        language.text("模型可用性", "Model availability")
    }

    static func summary(_ language: WidgetLanguage) -> String {
        language.text(
            "按模型分别记录；一个模型通过不代表该 CLI 全部可用。免费来源与测试状态分开显示。",
            "Recorded per model; one passing model does not make the whole CLI available. Free-source facts are separate from test status."
        )
    }

    static func emptyLine(_ language: WidgetLanguage) -> String {
        language.text("尚无模型测试证据。", "No model-test evidence yet.")
    }

    static func cardSummary(rows: [LocalCLIModelAvailabilityRow], language: WidgetLanguage) -> String {
        guard !rows.isEmpty else {
            return language.text("暂无验证记录", "No verification records")
        }
        let verified = rows.filter { $0.testStatus == .passed }.count
        return language.text(
            "可用模型 \(rows.count) · 已验证 \(verified)",
            "\(rows.count) models · \(verified) verified"
        )
    }

    static func sourceText(_ kind: LocalCLIFreeSourceKind?, language: WidgetLanguage) -> String? {
        switch kind {
        case .official: language.text("来源 官方", "Source official")
        case .userConfirmed: language.text("来源 用户确认", "Source user confirmed")
        case nil: nil
        }
    }

    static func confirmedText(_ day: LocalCLICivilInstant?, language: WidgetLanguage) -> String? {
        guard let day else { return nil }
        return language.text("确认日 \(day.displayText)", "Confirmed \(day.displayText)")
    }

    static func startText(_ start: LocalCLIOptionalInstant, language: WidgetLanguage) -> String? {
        guard let value = start.displayText else { return nil }
        return language.text(
            "起始 \(value)\(timezoneNote(start, language: language))",
            "Starts \(value)\(timezoneNote(start, language: language))"
        )
    }

    static func sourceURLText(_ url: URL?, language: WidgetLanguage) -> String? {
        guard let url else { return nil }
        return language.text("来源链接 \(url.absoluteString)", "Source URL \(url.absoluteString)")
    }

    static func deadlineText(
        _ deadline: LocalCLIOptionalInstant,
        window: LocalCLIFreeWindowState,
        language: WidgetLanguage
    ) -> String {
        let note = timezoneNote(deadline, language: language)
        switch window {
        case .expired:
            let value = deadline.displayText ?? language.text("未注明", "not stated")
            return language.text("截止 \(value)\(note)（已过期）", "Ends \(value)\(note) (expired)")
        case .upcoming:
            let value = deadline.displayText ?? language.text("未注明", "not stated")
            return language.text("截止 \(value)\(note)（未开始）", "Ends \(value)\(note) (not started)")
        case .active, .unknown:
            guard let value = deadline.displayText else {
                return language.text("截止 未注明", "End date not stated")
            }
            return language.text("截止 \(value)\(note)", "Ends \(value)\(note)")
        }
    }

    static func timezoneNote(_ instant: LocalCLIOptionalInstant, language: WidgetLanguage) -> String {
        instant.timezoneUnstated ? language.text("（时区未注明）", " (timezone not stated)") : ""
    }

    static func testText(status: LocalCLIModelTestStatus, testedAt: Date?, language: WidgetLanguage) -> String {
        let statusText: String
        switch status {
        case .untested: statusText = language.text("未测试", "Untested")
        case .passed: statusText = language.text("通过", "Passed")
        case .invalid: statusText = language.text("失效", "Invalid")
        }
        guard let testedAt else { return language.text("测试 \(statusText)", "Test \(statusText)") }
        return language.text(
            "测试 \(statusText) · \(language.dateTime(testedAt))",
            "Test \(statusText) · \(language.dateTime(testedAt))"
        )
    }

    static func dispatchText(_ eligible: Bool, language: WidgetLanguage) -> String {
        eligible
            ? language.text("可用于受管派单", "Eligible for managed dispatch")
            : language.text("不可用于受管派单", "Not eligible for managed dispatch")
    }

    private static func relevantEvidence(
        snapshot: LocalCLIModelAvailabilitySnapshot,
        provider: LocalCLIKind,
        binding: LocalCLICurrentBinding?
    ) -> [LocalCLIModelTestEvidence] {
        guard snapshot.diskAccepted else { return [] }
        let scoped = snapshot.evidence.filter { $0.provider == provider }
        guard let binding else { return scoped }
        return scoped.filter {
            $0.accountFingerprint == binding.accountFingerprint
                && $0.environmentFingerprint == binding.environmentFingerprint
        }
    }
}
