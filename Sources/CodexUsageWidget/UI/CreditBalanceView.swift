import SwiftUI

struct CreditBalanceView: View {
    let presentation: CreditBalancePresentation
    var compact = false
    @Environment(\.widgetLanguage) private var language
    @State private var showingDetails = false

    var body: some View {
        Group {
            if compact {
                Button {
                    showingDetails.toggle()
                } label: {
                    Text(language.text("点数 ", "Credits ") + creditText)
                        .monospacedDigit().lineLimit(1)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(language.text("查看余额说明", "Show balance details"))
            } else {
                fullLabel
            }
        }
        .font(.system(size: compact ? 10 : 12))
        .help(helpText)
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) { balanceDetails }
    }

    private var fullLabel: some View {
        HStack(spacing: 6) {
            Text(language.text("点数 ", "Credits ") + creditText)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Button {
                showingDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .frame(width: compact ? 18 : 24, height: compact ? 18 : 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("余额说明", "Balance details"))
        }
    }

    private var creditText: String {
        guard presentation.value != .unavailable else { return "—" }
        guard compact, case .reported(let raw) = presentation.value else {
            return presentation.primaryText(language)
        }
        let normalized = raw.replacingOccurrences(of: ",", with: "")
        guard let decimal = Decimal(string: normalized) else {
            return CreditBalanceNumberText.compact(raw, locale: language.locale)
        }
        if decimal > 0 && decimal < Decimal(string: "0.005")! { return "<0.01" }
        let formatter = NumberFormatter()
        formatter.locale = language.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSDecimalNumber(decimal: decimal))
            ?? CreditBalanceNumberText.compact(raw, locale: language.locale)
    }

    private var balanceDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.primaryText(language))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Text(presentation.sourceText(language))
                .foregroundStyle(.secondary)
            if let snapshotAt = presentation.snapshotAt {
                Text(language.text("快照时间：", "Snapshot: ") + language.dateTime(snapshotAt))
                    .foregroundStyle(.secondary)
            }
            Text(presentation.explanation(language))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(14)
        .frame(width: 268, alignment: .leading)
        .background(.background)
    }

    private var helpText: String {
        var lines = [presentation.sourceText(language), presentation.explanation(language)]
        if let snapshotAt = presentation.snapshotAt {
            lines.insert(
                language.text("快照时间：", "Snapshot: ") + language.dateTime(snapshotAt),
                at: 1
            )
        }
        return lines.joined(separator: "\n")
    }

}
