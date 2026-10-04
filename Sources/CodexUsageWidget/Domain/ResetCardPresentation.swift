import Foundation

/// Pure presentation and sorting rules for Codex reset credits and local CLI reset cards.
/// Local CLI availability follows each provider's evidence contract; unknown data stays unknown.
enum ResetCardPresentation {
    /// A card counts as "expiring" only inside (0, 48h] before its expiry.
    static let expiringWindow: TimeInterval = 48 * 60 * 60

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
        language.text("48 小时内到期", "Expires within 48 hours")
    }

    /// Keep duplicate dates (separate cards), with upcoming expiries first and
    /// expired records last. Invalid dates are never useful presentation data.
    static func orderedExpiries(_ dates: [Date], now: Date) -> [Date] {
        dates.filter { $0.timeIntervalSince1970.isFinite }.sorted {
            if ($0 > now) != ($1 > now) { return $0 > now }
            return $0 < $1
        }
    }

    struct ExpiryDisclosure: Equatable {
        let inlineText: String?
        let tooltip: String
    }

    static func expiryDisclosure(
        count: Int?, expiries: [Date], fetchedAt: Date?, readSucceeded: Bool,
        now: Date, language: WidgetLanguage
    ) -> ExpiryDisclosure {
        let dates = orderedExpiries(expiries, now: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = [language.text("到期时间 · 北京时间（UTC+8）", "Expiry · Beijing time (UTC+8)")]
        if !readSucceeded {
            lines.append(language.text("读取未成功 · 上次记录", "Read unsuccessful · previous records"))
        } else if !isFresh(fetchedAt, now: now) {
            lines.append(language.text("上次快照 · 待刷新", "Last snapshot · refresh needed"))
        }
        for date in dates {
            lines.append(formatter.string(from: date) + (date <= now ? language.text("（已过记录日期）", " (past recorded date)") : ""))
        }
        if let count, count >= 0 {
            let missing = max(0, count - dates.count)
            if missing > 0 { lines.append(language.text("另 \(missing) 张未提供到期时间", "\(missing) other cards have no reported expiry")) }
            if count < dates.count { lines.append(language.text("数量与日期记录不一致 · 待核实", "Count and recorded dates differ · verification needed")) }
            if count == 0 && dates.isEmpty { lines.append(language.text("没有可用重置卡", "No available reset cards")) }
        } else {
            lines.append(language.text("可用数量未确认", "Available count unconfirmed"))
        }
        if dates.isEmpty { lines.append(language.text("未提供到期时间", "No expiry reported")) }
        formatter.dateFormat = "MM-dd HH:mm"
        let upcoming = dates.filter { $0 > now }.prefix(ResetCreditDisclosure.inlineDetailLimit)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let text = upcoming.map { date in
            formatter.dateFormat =
                calendar.component(.year, from: date) == calendar.component(.year, from: now)
                ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm"
            return formatter.string(from: date)
        }.joined(separator: " · ")
        let prefix =
            !readSucceeded || !isFresh(fetchedAt, now: now) || count == nil || (count ?? 0) < dates.count
            ? language.text("记录 ", "Recorded ") : ""
        return ExpiryDisclosure(
            inlineText: text.isEmpty ? nil : prefix + text + language.text(" 北京时间", " UTC+8"),
            tooltip: lines.joined(separator: "\n"))
    }

    /// Earliest future expiry across the known cards, or `nil` when the set of
    /// cards is unknown. Zero cards or cards without an expiry return `nil` too;
    /// they mean "nothing to show", never "0 cards known to be expiring".
    static func earliestValidExpiry(_ cards: [LocalCLIResetCard]?, now: Date) -> Date? {
        guard let cards else { return nil }
        return cards.compactMap(\.expiresAt).filter { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince(now) > 0 }.min()
    }

    /// 48-hour red-frame rule: strictly future and at most 48 hours away.
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
