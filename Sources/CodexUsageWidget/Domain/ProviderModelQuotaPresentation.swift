import Foundation

enum ProviderQuotaDisplayStatus: Equatable, Sendable {
    case current, unknown, stale, expired, stopped
}

/// A display-only reading. A missing share is never a full or empty allowance.
struct ProviderQuotaDisplayRow: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var modelID: String? = nil
    var remainingFraction: Double? = nil
    var resetsAt: Date? = nil
    var observedAt: Date? = nil
    var status: ProviderQuotaDisplayStatus = .unknown
    var isShared = false
    var isFamily = false
    var remainingAmount: Double? = nil
    var totalAmount: Double? = nil
    var unit: String? = nil
    var members: [String] = []
    var unknownCount = 0
    var pool: String? = nil
    var windowSeconds: Int64? = nil

    var remainingPercent: Double? {
        guard status == .current, let remainingFraction,
            remainingFraction.isFinite, (0...1).contains(remainingFraction)
        else { return nil }
        return remainingFraction * 100
    }
}

enum ProviderModelQuotaPresentation {
    static let maximumAge: TimeInterval = 15 * 60

    static func status(fraction: Double?, reset: Date?, observed: Date?, isRunning: Bool, now: Date) -> ProviderQuotaDisplayStatus {
        guard isRunning else { return .stopped }
        if let reset, reset <= now { return .expired }
        guard let observed else { return .unknown }
        guard observed <= now.addingTimeInterval(5), now.timeIntervalSince(observed) <= maximumAge else { return .stale }
        guard let fraction, fraction.isFinite, (0...1).contains(fraction) else { return .unknown }
        return .current
    }

    /// Real IDs only; effort variants keep the ID the existing launcher accepts.
    static func models(account: AntigravityProxyAccount, isRunning: Bool, now: Date) -> [ProviderQuotaDisplayRow] {
        let details = account.modelDetails ?? []
        let hidden = Set(details.filter { $0.disabled == true }.map(\.id))
        var seen = Set<String>()
        let active = isRunning && account.enabled && account.state != .disabled && account.state != .reauthRequired
        let observed = account.modelDetailsObservedAt
        var rows: [ProviderQuotaDisplayRow] = []
        for detail in details where visible(detail.id, provider: account.provider) && !hidden.contains(detail.id) && seen.insert(detail.id).inserted {
            rows.append(
                .init(
                    id: detail.id, title: detail.displayName.isEmpty ? detail.id : detail.displayName, modelID: detail.id,
                    remainingFraction: detail.remainingFraction, resetsAt: detail.resetsAt, observedAt: observed,
                    status: status(fraction: detail.remainingFraction, reset: detail.resetsAt, observed: observed, isRunning: active, now: now)))
        }
        for id in account.models where visible(id, provider: account.provider) && !hidden.contains(id) && seen.insert(id).inserted {
            rows.append(.init(id: id, title: id, modelID: id, observedAt: observed, status: active ? .unknown : .stopped))
        }
        return rows
    }

    static func shared(account: AntigravityProxyAccount, isRunning: Bool, now: Date) -> [ProviderQuotaDisplayRow] {
        let active = isRunning && account.enabled && account.state != .disabled && account.state != .reauthRequired
        let observed = account.modelDetailsObservedAt
        return orderedSharedRows(
            (account.sharedWindows ?? []).map { window in
                .init(
                    id: "shared:" + window.id, title: window.pool.isEmpty ? window.label : window.pool + " · " + window.label,
                    remainingFraction: window.remainingFraction, resetsAt: window.resetsAt, observedAt: observed,
                    status: status(fraction: window.remainingFraction, reset: window.resetsAt, observed: observed, isRunning: active, now: now),
                    isShared: true, remainingAmount: window.remainingAmount, totalAmount: window.totalAmount, unit: window.unit,
                    members: window.modelIDs ?? [], pool: window.pool, windowSeconds: window.windowSeconds)
            })
    }

    /// A shared window replaces model readings only with confirmed membership
    /// and the same 5-hour span. A weekly-only pool never hides those readings.
    static func summary(account: AntigravityProxyAccount, models: [ProviderQuotaDisplayRow], shared: [ProviderQuotaDisplayRow]) -> [ProviderQuotaDisplayRow] {
        guard account.provider == .antigravity else { return shared }
        let covered = Set(
            (account.sharedWindows ?? [])
                .filter { $0.windowSeconds == 5 * 60 * 60 }
                .flatMap { $0.modelIDs ?? [] })
        return overview(models: models, shared: shared, coveredModelIDs: covered)
    }

    /// Common to local and authorized Antigravity accounts. A weekly-only
    /// family pool follows the models' five-hour reading, as in Magpie.
    static func overview(models: [ProviderQuotaDisplayRow], shared: [ProviderQuotaDisplayRow], coveredModelIDs: Set<String> = []) -> [ProviderQuotaDisplayRow] {
        let shared = orderedSharedRows(shared)
        let uncovered = models.filter { !coveredModelIDs.contains($0.id) }
        let standalone: (ProviderQuotaDisplayRow) -> Bool = { row in
            guard row.remainingPercent != nil else { return false }
            return shared.contains { window in
                guard window.windowSeconds == 18000, let pool = window.pool,
                    pool.rangeOfCharacter(from: .decimalDigits) == nil
                else { return false }
                let name = family(row)
                return pool.localizedCaseInsensitiveContains(name)
                    || (name == "GPT-OSS" && pool.localizedCaseInsensitiveContains("GPT"))
            }
        }
        // A model that is not confirmed in an existing family pool keeps its
        // own name and reading. Calling it the family's quota would hide an
        // independent allowance behind another generic "Gemini" ring.
        var independentModels = uncovered.filter(standalone)
        var remainingFamilies = families(uncovered.filter { !standalone($0) })
        var pools: [String] = []
        for row in shared {
            let pool = row.pool ?? row.title
            if !pools.contains(pool) { pools.append(pool) }
        }
        var result: [ProviderQuotaDisplayRow] = []
        for pool in pools {
            let own = shared.filter { ($0.pool ?? $0.title) == pool }
            if pool.rangeOfCharacter(from: .decimalDigits) != nil {
                // Independent model pools follow every family's overview.
                result.append(contentsOf: remainingFamilies)
                remainingFamilies.removeAll()
                result.append(contentsOf: independentModels)
                independentModels.removeAll()
            } else if !own.contains(where: { $0.windowSeconds == 18000 }) {
                let belongs: (ProviderQuotaDisplayRow) -> Bool = { row in
                    pool.localizedCaseInsensitiveContains(family(row))
                }
                result.append(contentsOf: remainingFamilies.filter(belongs))
                remainingFamilies.removeAll(where: belongs)
            }
            result.append(contentsOf: own)
        }
        return result + remainingFamilies + independentModels
    }

    static func orderedSharedRows(_ rows: [ProviderQuotaDisplayRow]) -> [ProviderQuotaDisplayRow] {
        let poolName: (ProviderQuotaDisplayRow) -> String = { $0.pool ?? $0.title }
        var order: [String: Int] = [:]
        for row in rows where order[poolName(row)] == nil { order[poolName(row)] = order.count }
        let rank: (String) -> Int = { pool in
            if pool.rangeOfCharacter(from: .decimalDigits) != nil { return 3 }
            return familyRank(pool.components(separatedBy: CharacterSet(charactersIn: " &")).first ?? pool)
        }
        return rows.enumerated().sorted { left, right in
            let a = left.element
            let b = right.element
            let ap = poolName(a)
            let bp = poolName(b)
            if rank(ap) != rank(bp) { return rank(ap) < rank(bp) }
            if ap != bp { return order[ap]! < order[bp]! }
            let aspan = a.windowSeconds ?? .max
            let bspan = b.windowSeconds ?? .max
            return aspan == bspan ? left.offset < right.offset : aspan < bspan
        }.map(\.element)
    }

    static func families(_ rows: [ProviderQuotaDisplayRow]) -> [ProviderQuotaDisplayRow] {
        var order: [String] = []
        var groups: [String: [ProviderQuotaDisplayRow]] = [:]
        for row in rows {
            let name = family(row)
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(row)
        }
        order = order.enumerated().sorted { left, right in
            let a = familyRank(left.element)
            let b = familyRank(right.element)
            return a == b ? left.offset < right.offset : a < b
        }.map(\.element)
        return order.compactMap { name in
            guard let members = groups[name], var tightest = members.first else { return nil }
            guard members.count > 1 else { return tightest }
            for row in members.dropFirst() {
                if let value = row.remainingPercent,
                    tightest.remainingPercent == nil || value < tightest.remainingPercent!
                        || (value == tightest.remainingPercent && (row.resetsAt ?? .distantFuture) < (tightest.resetsAt ?? .distantFuture))
                {
                    tightest = row
                }
            }
            // Unknown models remain in Every model. The overview can still say
            // the tightest known reading, with the unknown count beside it.
            tightest.unknownCount = members.filter { $0.remainingPercent == nil }.count
            tightest.id = "family:" + name
            tightest.title = name
            tightest.modelID = nil
            tightest.isFamily = true
            tightest.members = members.map { $0.modelID ?? $0.title }
            return tightest
        }
    }

    static func visible(_ id: String, provider: AntigravityProxyProvider) -> Bool {
        provider != .antigravity || (!id.hasPrefix("chat_") && !id.hasPrefix("tab_"))
    }

    private static func family(_ row: ProviderQuotaDisplayRow) -> String {
        let id = (row.modelID ?? row.id).lowercased()
        if id.hasPrefix("gemini") { return "Gemini" }
        if id.hasPrefix("claude") { return "Claude" }
        if id.hasPrefix("gpt-oss") { return "GPT-OSS" }
        return row.title.split(separator: " ").first.map(String.init) ?? row.title
    }

    private static func familyRank(_ value: String) -> Int {
        switch value {
        case "Gemini": 0
        case "Claude": 1
        default: 2
        }
    }

}
