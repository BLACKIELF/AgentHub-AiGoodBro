import SwiftUI

/// Exact counts are shown only when the provider reports a token allowance.
struct LocalCLIQuotaWindowDetails: View {
    let window: LocalCLIQuotaWindow
    let language: WidgetLanguage

    var body: some View {
        let percentages = Self.percentages(usedPercent: window.usedPercent, language: language)
        VStack(alignment: .leading, spacing: 2) {
            if let amount = window.tokenAmountText { Text(amount).monospacedDigit() }
            Text(language.text("已用 ", "Used ") + percentages.used
                + " · " + language.text("剩余 ", "Remaining ") + percentages.remaining)
            Text(
                window.resetsAt.map {
                    (window.isExpiry ? language.text("到期：", "Expires: ") : language.text("重置：", "Resets: "))
                        + language.dateTime($0)
                }
                    ?? language.text("重置时间：暂不可确认", "Reset time: unavailable"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func percentages(usedPercent: Double, language: WidgetLanguage) -> (used: String, remaining: String) {
        guard usedPercent.isFinite else { return ("—", "—") }
        let used = (min(100, max(0, usedPercent)) * 10).rounded() / 10
        func text(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(0...1)).locale(language.locale)) + "%"
        }
        // Round once so complementary values cannot display a total of 101%.
        return (text(used), text(100 - used))
    }
}
