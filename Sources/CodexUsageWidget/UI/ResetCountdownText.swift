import SwiftUI

enum ResetCountdownPresentation {
    enum Kind { case publicForecast, accountWindow }

    /// Always derive the remaining time from the deadline, including after sleep
    /// or a clock correction. A countdown never changes a quota or confirms a reset.
    static func label(deadline: Date?, now: Date, kind: Kind, language: WidgetLanguage) -> String {
        guard let deadline else { return unknown(kind, language: language) }
        let interval = deadline.timeIntervalSince(now)
        guard interval.isFinite, abs(interval) < Double(Int.max) else {
            return unknown(kind, language: language)
        }
        guard interval > 0 else {
            return kind == .publicForecast
                ? language.text("预告时间已到，等待来源确认", "Forecast time reached; awaiting confirmation")
                : language.text("时间已到，等待额度更新", "Time reached; awaiting quota update")
        }
        let seconds = Int(ceil(interval))
        let days = seconds / 86_400
        let clock = String(format: "%02d:%02d:%02d", (seconds % 86_400) / 3_600, (seconds % 3_600) / 60, seconds % 60)
        let duration = days > 0 ? language.text("\(days) 天 ", "\(days)d ") + clock : clock
        return
            (kind == .publicForecast
            ? language.text("最晚还有 ", "Due within ")
            : language.text("重置还有 ", "Resets in ")) + duration
    }

    private static func unknown(_ kind: Kind, language: WidgetLanguage) -> String {
        kind == .publicForecast
            ? language.text("时间待公开来源公布", "Time has not yet been announced by the public source")
            : language.text("重置时间未知", "Reset time unknown")
    }
}

/// Only this small label ticks. It does not refresh the account or its parent page.
struct ResetCountdownText: View {
    let deadline: Date
    let kind: ResetCountdownPresentation.Kind
    let language: WidgetLanguage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(ResetCountdownPresentation.label(deadline: deadline, now: context.date, kind: kind, language: language))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(kind == .publicForecast && deadline > context.date ? FixedVisualPalette.statusWarning : Color.secondary)
        }
        .accessibilityIdentifier(kind == .publicForecast ? "public-reset-countdown" : "account-reset-countdown")
    }
}
