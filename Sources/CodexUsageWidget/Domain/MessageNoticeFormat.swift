import Foundation

/// Pure presentation for existing notices. Raw task/code text is wrapped or
/// split without editing its bytes; only generated summaries may be shortened.
enum MessageNoticeFormat {
    static let footer = "aigoodbro.com"
    static let footerSuffix = "\n\n" + footer
    static let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = beijingTimeZone
        return value
    }

    private static func formatted(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = beijingTimeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    static func shortTime(_ date: Date, now: Date = Date()) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return formatted(date, pattern: "HH:mm") }
        return shortDate(date, now: now)
    }

    /// Expiry timestamps always retain their month and day.
    static func shortDate(_ date: Date, now: Date = Date()) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatted(date, pattern: sameYear ? "MM/dd HH:mm" : "yy/MM/dd HH:mm")
    }

    static func range(from start: Date, to end: Date, now: Date = Date(), alwaysDates: Bool = false) -> String {
        let startYear = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)
        let currentYear = calendar.component(.year, from: now)
        if startYear != endYear || startYear != currentYear || endYear != currentYear {
            return formatted(start, pattern: "yy/MM/dd HH:mm") + "→" + formatted(end, pattern: "yy/MM/dd HH:mm")
        }
        if !alwaysDates, calendar.isDate(start, inSameDayAs: end) {
            return shortTime(start, now: now) + "→" + formatted(end, pattern: "HH:mm")
        }
        return shortDate(start, now: now) + "→" + shortDate(end, now: now)
    }

    /// Floor whole minutes: formatting must never promise extra usable time.
    static func remaining(until deadline: Date, now: Date = Date()) -> String {
        let seconds = deadline.timeIntervalSince(now)
        guard seconds.isFinite, seconds < Double(Int.max) else { return "—" }
        guard seconds > 0 else { return "0m" }
        guard seconds >= 60 else { return "<1m" }
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(minutes)m" }
        return "\(hours)h" + (remainder == 0 ? "" : "\(remainder)m")
    }

    private static func generatedBody(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeLast() }
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == footer {
            lines.removeLast()
            while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeLast() }
        }
        return lines.joined(separator: "\n")
    }

    /// Idempotent only for application-generated wrappers, never source text.
    static func withFooter(_ generated: String) -> String {
        let body = generatedBody(generated)
        return body.isEmpty ? footer : body + footerSuffix
    }

    /// A literal source line that happens to contain the brand is preserved.
    static func preservingOriginalBody(_ raw: String) -> String { raw + footerSuffix }

    static func boundedSummary(_ summary: String, characterLimit: Int) -> String {
        let body = generatedBody(summary)
        let complete = withFooter(body)
        guard complete.count > characterLimit else { return complete }
        let budget = max(0, characterLimit - footerSuffix.count - 1)
        return withFooter(String(body.prefix(budget)) + "…")
    }

    static func bodyUTF8Budget(limit: Int) -> Int { max(0, limit - footerSuffix.utf8.count) }
    static func bodyUTF16Budget(limit: Int) -> Int { max(0, limit - footerSuffix.utf16.count) }

    static func validChange(previous: Int, available: Int, previousObservedAt: Date, observedAt: Date) -> Bool {
        previous >= 0 && available >= 0 && previous != available
            && previousObservedAt.timeIntervalSince1970.isFinite && observedAt.timeIntervalSince1970.isFinite
            && previousObservedAt < observedAt
    }

    static func validExpiry(_ batches: [CodexResetCreditExpiryBatch], observedAt: Date, enforcingThreshold: Bool = true) -> Bool {
        guard observedAt.timeIntervalSince1970.isFinite, !batches.isEmpty, batches.count <= 1_024 else { return false }
        return batches.allSatisfy {
            let remaining = $0.expiresAt.timeIntervalSince(observedAt)
            return $0.count > 0 && remaining.isFinite && remaining > 0 && (!enforcingThreshold || remaining <= 24 * 3600)
        } && Set(batches.map(\.expiresAt)).count == batches.count
    }

    /// Dispatch freshness is separate from when the account fact was verified.
    static func checkedAt(for event: CodexQuotaEvent?, fallback: Date) -> Date {
        switch event {
        case .resetCreditsChanged(_, _, _, let observedAt), .resetCreditsExpiring(_, let observedAt): return observedAt
        default: return fallback
        }
    }

    static func changeTitle(previous: Int, available: Int, language: WidgetLanguage) -> String {
        let delta = available - previous
        let amount = delta > 0 ? "+\(delta)" : String(delta)
        return language.text("重置卡 \(amount)", "Reset credits \(amount)")
    }

    static func changeLines(previous: Int, available: Int, previousObservedAt: Date, observedAt: Date, language: WidgetLanguage) -> [String] {
        var lines = [
            language.text("可用 \(previous)→\(available) 次", "Available \(previous)→\(available)"),
            language.text("净变化 · 快照 ", "Net change · snapshots ")
                + range(from: previousObservedAt, to: observedAt, alwaysDates: observedAt.timeIntervalSince(previousObservedAt) > 45 * 60),
        ]
        if available < previous { lines.append(language.text("原因待核实", "Reason unverified")) }
        return lines
    }

    static func expiryLines(_ batches: [CodexResetCreditExpiryBatch], language: WidgetLanguage, now: Date = Date()) -> [String] {
        batches.sorted { $0.expiresAt < $1.expiresAt }.map {
            let when = shortDate($0.expiresAt, now: now)
            let left = remaining(until: $0.expiresAt, now: now)
            return language.text("\($0.count)次 · \(when)到期（余\(left)）", "\($0.count) · expires \(when) (\(left) left)")
        }
    }

    /// No truncation, normalization or automatic retry. The caller journals
    /// each send and stops on uncertain outcomes before attempting another part.
    static func originalChunks(_ raw: String, utf8Limit: Int) -> [String]? {
        let budget = bodyUTF8Budget(limit: utf8Limit)
        guard budget > 0, !raw.isEmpty else { return nil }
        var parts: [String] = []
        var part = ""
        var bytes = 0
        for character in raw {
            let size = String(character).utf8.count
            guard size <= budget else { return nil }
            if bytes + size > budget {
                parts.append(preservingOriginalBody(part))
                part = ""
                bytes = 0
            }
            part.append(character)
            bytes += size
        }
        if !part.isEmpty { parts.append(preservingOriginalBody(part)) }
        return parts
    }

    static func state(_ state: MessageTaskStatus.TaskState, language: WidgetLanguage) -> String {
        switch state {
        case .idle: return language.text("等待处理", "Waiting")
        case .running: return language.text("进行中", "Running")
        case .waitingInput: return language.text("待确认", "Needs input")
        case .completed: return language.text("运行结束", "Run ended")
        case .failed: return language.text("失败", "Failed")
        case .interrupted: return language.text("已中断", "Interrupted")
        case .disconnected: return language.text("连接中断", "Disconnected")
        }
    }

    static func reason(_ reason: MessageTaskStatus.FailureReason, language: WidgetLanguage) -> String {
        switch reason {
        case .noEligibleAccount: return language.text("暂无可用账号", "No eligible account")
        case .appBusy: return language.text("应用忙碌，请稍后再试", "App busy; try later")
        case .validationFailed: return language.text("账号核验未通过", "Account verification failed")
        case .restartFailed: return language.text("重新连接未完成", "Reconnect failed")
        case .networkUnavailable: return language.text("网络暂不可用", "Network unavailable")
        case .unknown: return language.text("原因待核实", "Reason unverified")
        }
    }
}

enum MessageNoticeFormatSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ value: @autoclosure () -> Bool, _ name: String) {
            if !value() { failures.append(name) }
        }
        func date(_ value: String) -> Date {
            ISO8601DateFormatter().date(from: value)!
        }
        let now = date("2026-10-12T02:00:00Z")
        let early = date("2026-10-12T01:30:00Z")
        let yesterday = date("2026-10-11T01:30:00Z")
        expect(MessageNoticeFormat.shortTime(early, now: now) == "09:30", "today clock")
        expect(MessageNoticeFormat.shortTime(yesterday, now: now) == "10/11 09:30", "other day clock")
        expect(MessageNoticeFormat.shortDate(early, now: now) == "10/12 09:30", "expiry day retained")
        expect(MessageNoticeFormat.range(from: early, to: now, now: now) == "09:30→10:00", "today range")
        expect(MessageNoticeFormat.range(from: yesterday, to: yesterday.addingTimeInterval(1800), now: now) == "10/11 09:30→10:00", "other day range")
        expect(MessageNoticeFormat.range(from: date("2026-10-12T15:50:00Z"), to: date("2026-10-12T16:10:00Z"), now: now) == "10/12 23:50→10/13 00:10", "Beijing cross day")
        expect(MessageNoticeFormat.range(from: date("2026-12-31T15:50:00Z"), to: date("2026-12-31T16:10:00Z"), now: now) == "26/12/31 23:50→27/01/01 00:10", "cross year range")
        expect(MessageNoticeFormat.range(from: early, to: now, now: now, alwaysDates: true) == "10/12 09:30→10/12 10:00", "dated evidence range")
        for (seconds, expected) in [(23.0 * 3600, "23h"), (5400.0, "1h30m"), (3599.9, "59m"), (359.9, "5m"), (59.9, "<1m"), (0.0, "0m")] {
            expect(MessageNoticeFormat.remaining(until: now.addingTimeInterval(seconds), now: now) == expected, "floored remaining \(expected)")
        }
        let generated = "连接测试\n\naigoodbro.com\n\naigoodbro.com\n"
        let wrapped = MessageNoticeFormat.withFooter(generated)
        expect(wrapped == "连接测试" + MessageNoticeFormat.footerSuffix, "generated footer dedupe")
        expect(MessageNoticeFormat.withFooter(wrapped) == wrapped, "generated footer idempotence")
        let source = "```swift\nlet site = \"aigoodbro.com\"\n```\n\naigoodbro.com\n"
        expect(MessageNoticeFormat.preservingOriginalBody(source) == source + MessageNoticeFormat.footerSuffix, "raw source preservation")
        let long = String(repeating: "中文🙂\n", count: 900) + "e\u{0301}" + source
        if let parts = MessageNoticeFormat.originalChunks(long, utf8Limit: 4096) {
            expect(parts.count > 1 && parts.allSatisfy { $0.utf8.count <= 4096 && $0.hasSuffix(MessageNoticeFormat.footerSuffix) }, "chunk limit and footer")
            let joined = parts.map { String($0.dropLast(MessageNoticeFormat.footerSuffix.count)) }.joined()
            expect(Array(joined.utf8) == Array(long.utf8), "chunk reconstruction preserves all source bytes")
        } else {
            failures.append("long source chunking")
        }
        let unbreakable = "a" + String(repeating: "\u{0301}", count: 3000)
        expect(MessageNoticeFormat.originalChunks(unbreakable, utf8Limit: 4096) == nil, "oversized grapheme fails closed")
        let bounded = MessageNoticeFormat.boundedSummary(String(repeating: "摘要", count: 500), characterLimit: 500)
        expect(bounded.count <= 500 && bounded.hasSuffix(MessageNoticeFormat.footerSuffix), "summary reserves footer")
        expect(MessageNoticeFormat.bodyUTF8Budget(limit: 4096) + MessageNoticeFormat.footerSuffix.utf8.count == 4096, "UTF8 budget")
        expect(MessageNoticeFormat.bodyUTF16Budget(limit: 4096) + MessageNoticeFormat.footerSuffix.utf16.count == 4096, "UTF16 budget")
        let crossing = [CodexResetCreditExpiryBatch(expiresAt: now.addingTimeInterval(24 * 3600 + 30), count: 1)]
        expect(MessageNoticeFormat.validExpiry(crossing, observedAt: now, enforcingThreshold: false), "original snapshot retains a later expiry")
        expect(!MessageNoticeFormat.validExpiry(crossing, observedAt: now), "current expiry beyond 24h rejected")
        expect(MessageNoticeFormat.validExpiry(crossing, observedAt: now.addingTimeInterval(60)), "cached expiry enters the 24h window")
        expect(MessageNoticeFormat.checkedAt(for: .resetCreditsExpiring(batches: crossing, observedAt: early), fallback: now) == early, "cached expiry retains original check time")
        expect(MessageNoticeFormat.state(.completed, language: .zh) == "运行结束", "run end is not acceptance")
        expect(MessageNoticeFormat.reason(.unknown, language: .zh) == "原因待核实", "unknown remains unverified")
        if failures.isEmpty {
            print("Message notice format self-test passed")
            return true
        }
        failures.forEach { print("Message notice format self-test failed: \($0)") }
        return false
    }
}
