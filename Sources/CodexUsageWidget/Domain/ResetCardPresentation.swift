import Foundation

/// Pure presentation and sorting rules for the reset cards carried by
/// `LocalCLIQuotaResult.resetCards` (DTO defined next to it in LocalCLIAccount.swift).
/// See that type's contract: the official Grok response has no card fields today, so
/// production data is `nil`; the rules below are exercised by synthetic fixtures only.
enum ResetCardPresentation {
    /// A card counts as "expiring" only inside (0, 72h] before its expiry.
    static let expiringWindow: TimeInterval = 72 * 60 * 60

    static func isFresh(_ fetchedAt: Date?, now: Date) -> Bool {
        guard let fetchedAt else { return false }
        let age = now.timeIntervalSince(fetchedAt)
        return age.isFinite && age >= 0 && age <= 300
    }

    static func codexKey(_ profileID: String) -> String { "codex:\(profileID)" }
    static func localKey(kind: String, profileID: String) -> String { "local:\(kind):\(profileID)" }

    static func codexIsExpiring(available: Int?, expiries: [Date], fetchedAt: Date?, readSucceeded: Bool, now: Date) -> Bool {
        guard readSucceeded, (available ?? 0) > 0, isFresh(fetchedAt, now: now) else { return false }
        return expiries.contains {
            let remaining = $0.timeIntervalSince(now)
            return remaining.isFinite && remaining > 0 && remaining <= expiringWindow
        }
    }

    static func unavailableText(language: WidgetLanguage) -> String {
        language.text("重置卡信息暂不可用", "Reset-card information unavailable")
    }

    static func expiringLabelText(language: WidgetLanguage) -> String {
        language.text("72 小时内到期", "Expires within 72 hours")
    }

    /// Earliest future expiry across the known cards, or `nil` when the set of
    /// cards is unknown. Zero cards or cards without an expiry return `nil` too;
    /// they mean "nothing to show", never "0 cards known to be expiring".
    static func earliestValidExpiry(_ cards: [LocalCLIResetCard]?, now: Date) -> Date? {
        guard let cards else { return nil }
        return cards.compactMap(\.expiresAt).filter { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince(now) > 0 }.min()
    }

    /// 72-hour red-frame rule: strictly future and at most 72 hours away.
    /// Already expired, unknown and stale evidence never count as expiring.
    static func isExpiringSoon(_ cards: [LocalCLIResetCard]?, now: Date, evidenceFresh: Bool = true) -> Bool {
        guard evidenceFresh, let earliest = earliestValidExpiry(cards, now: now) else { return false }
        let remaining = earliest.timeIntervalSince(now)
        return remaining > 0 && remaining <= expiringWindow
    }

    /// Quota refresh and expiry badges must never move accounts under the pointer.
    /// Only an explicit pin overrides the saved order.
    static func savedOrder(_ ids: [String], pinnedAccountID: String?) -> [String] {
        guard let pinnedAccountID, ids.contains(pinnedAccountID) else { return ids }
        return [pinnedAccountID] + ids.filter { $0 != pinnedAccountID }
    }

    /// One-line card summary: the unavailable text for unknown data, nothing for a
    /// known empty list, otherwise the card count plus the earliest valid expiry.
    static func summaryText(_ cards: [LocalCLIResetCard]?, now: Date, timeZone: TimeZone, language: WidgetLanguage) -> String? {
        guard let cards else { return unavailableText(language: language) }
        let available = cards.filter { card in
            guard let expiry = card.expiresAt, expiry.timeIntervalSince1970.isFinite else { return true }
            return expiry > now
        }
        guard !available.isEmpty else { return nil }
        let countText = language.text("\(available.count) 张重置卡", "\(available.count) reset cards")
        guard let earliest = earliestValidExpiry(available, now: now) else {
            return language.text("\(countText) · 到期待确认", "\(countText) · expiry unknown")
        }
        return language.text(
            "\(countText) · 最早 \(expiryText(earliest, timeZone: timeZone, language: language))",
            "\(countText) · earliest \(expiryText(earliest, timeZone: timeZone, language: language))")
    }

    /// Time-zone aware expiry rendering so a card expiring "09:55 Shanghai"
    /// never reads as a different local time elsewhere.
    static func expiryText(_ date: Date, timeZone: TimeZone, language: WidgetLanguage) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: language.locale, calendar: calendar, timeZone: timeZone)
        return style.format(date)
    }
}
