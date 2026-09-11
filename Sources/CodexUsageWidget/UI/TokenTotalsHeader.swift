import SwiftUI

/// Shared presentation for the lifetime token total shown in the main window
/// and the account menu. The values are supplied by each existing owner so the
/// accounting and high-water-mark semantics stay local to those owners.
struct TokenTotalsHeader: View {
    enum Layout: Equatable {
        case hero
        case compact

        var titleFont: Font {
            switch self {
            case .hero: return .headline
            case .compact: return .system(size: 12, weight: .semibold)
            }
        }

        var totalFont: Font {
            switch self {
            case .hero: return .system(size: 32, weight: .bold, design: .rounded)
            case .compact: return .system(size: 28, weight: .bold, design: .rounded)
            }
        }

        var labelFont: Font {
            switch self {
            case .hero: return .caption.weight(.semibold)
            case .compact: return .system(size: 10.5, weight: .semibold)
            }
        }

        var valueFont: Font {
            switch self {
            case .hero: return .caption.weight(.semibold)
            case .compact: return .system(size: 12, weight: .semibold, design: .rounded)
            }
        }

        var spacing: CGFloat {
            switch self {
            case .hero: return 9
            case .compact: return 7
            }
        }
    }

    let layout: Layout
    let language: WidgetLanguage
    let combinedTokensTotal: Int64?
    let combinedEquivalentCostUSD: Double?
    let officialAccountsLifetimeTokens: Int64?
    let localAllAgentsLifetimeTokens: Int64?
    let officialAccountsStatsAsOf: Date?

    init(
        layout: Layout,
        language: WidgetLanguage,
        combinedTokensTotal: Int64?,
        combinedEquivalentCostUSD: Double?,
        officialAccountsLifetimeTokens: Int64?,
        localAllAgentsLifetimeTokens: Int64?,
        officialAccountsStatsAsOf: Date? = nil
    ) {
        self.layout = layout
        self.language = language
        self.combinedTokensTotal = combinedTokensTotal
        self.combinedEquivalentCostUSD = combinedEquivalentCostUSD
        self.officialAccountsLifetimeTokens = officialAccountsLifetimeTokens
        self.localAllAgentsLifetimeTokens = localAllAgentsLifetimeTokens
        self.officialAccountsStatsAsOf = officialAccountsStatsAsOf
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            Label(language.text("总 Token 消耗量", "Total Token Consumption"), systemImage: "chart.bar.xaxis")
                .font(layout.titleFont)
                .accessibilityAddTraits(.isHeader)

            Text(combinedTokensTotal.map(language.tokens) ?? language.text("暂无记录", "No records"))
                .font(layout.totalFont)
                .foregroundStyle(.tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(layout == .hero ? 0.72 : 0.6)

            Text(language.text("所有账号 + 本机全 Agent · 全时段", "All accounts + all local agents · lifetime"))
                .font(layout == .hero ? .caption2.weight(.medium) : .system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            supportingRows
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var supportingRows: some View {
        VStack(alignment: .leading, spacing: layout == .hero ? 5 : 4) {
            metricRow(
                label: language.text("官方合计", "Official total"),
                value: officialAccountsLifetimeTokens.map { language.tokens($0) + " Token" }
                    ?? language.text("暂不可用", "Unavailable"),
                tint: .accentColor,
                help: nil
            )
            if let officialAccountsStatsAsOf {
                Text(
                    language.text("统计至 ", "As of ")
                        + officialAccountsStatsAsOf.formatted(.dateTime.month().day().locale(language.locale))
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
            }
            metricRow(
                label: language.text("本机全 Agent", "All local agents"),
                value: localAllAgentsLifetimeTokens.map { language.tokens($0) + " Token" }
                    ?? language.text("暂无记录", "No records"),
                tint: .accentColor,
                help: language.text(
                    "本机记录的全部 Agent（Codex、Claude Code、ZCode、自定义来源等）全时段 token 总和，本地口径",
                    "Lifetime tokens from local records across Codex, Claude Code, ZCode and custom sources."
                )
            )
            if let cost = combinedEquivalentCostUSD {
                metricRow(
                    label: language.text("API 等效估算", "API equivalent estimate"),
                    value: String(format: "≈ $%.0f", cost),
                    tint: .secondary,
                    help: language.text(
                        "按本机记录估算的 API 等效美元，不是账单，也不是汇率换算。",
                        "Local API-equivalent USD estimate. Not a bill and not a currency conversion."
                    )
                )
            }
        }
    }

    @ViewBuilder
    private func metricRow(label: String, value: String, tint: Color, help: String?) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(layout.labelFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Text(value)
                .font(layout.valueFont)
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        if let help {
            row.help(help)
        } else {
            row
        }
    }
}
