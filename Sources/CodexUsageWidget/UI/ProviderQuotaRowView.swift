import SwiftUI

/// Uses the same ring, palette, type and sizes as Codex's quota rows.
struct ProviderQuotaRowView: View {
    let row: ProviderQuotaDisplayRow
    let language: WidgetLanguage
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: WorkspaceVisualMetrics.Space.xs) {
            QuotaPercentageRing(percent: row.remainingPercent, diameter: compact ? 36 : 42)
                .fixedSize()
            VStack(alignment: .leading, spacing: WorkspaceVisualMetrics.Space.xxs) {
                Text(title).font(compact ? WorkspaceVisualMetrics.metaFont().weight(.semibold) : WorkspaceVisualMetrics.bodyFont().weight(.semibold))
                    .lineLimit(2).textSelection(.enabled)
                if let model = row.modelID, model != row.title {
                    Text(model).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(model).textSelection(.enabled)
                }
                Text(valueText).font(WorkspaceVisualMetrics.metaFont()).foregroundStyle(.secondary)
                if row.unknownCount > 0 {
                    Text(language.text("还有 \(row.unknownCount) 个模型额度未知", "\(row.unknownCount) model allowances are unknown"))
                        .font(WorkspaceVisualMetrics.metaFont()).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    if let reset = row.resetsAt {
                        Text(language.text("重置", "Resets"))
                        Text(language.dateTime(reset))
                    } else {
                        Text(language.text("重置时间未知", "Reset time unknown"))
                    }
                }.font(WorkspaceVisualMetrics.metaFont()).foregroundStyle(.secondary)
                if let reset = row.resetsAt, row.status == .current {
                    ResetCountdownText(deadline: reset, kind: .accountWindow, language: language, compact: true)
                        .font(WorkspaceVisualMetrics.metaFont()).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(row.members.isEmpty ? title : title + "\n" + row.members.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        guard row.isShared else { return row.title }
        return row.title.components(separatedBy: " · ").map { part in
            switch part {
            case "5 hours", "5-hour": language.text("5 小时", "5 hours")
            case "7 days", "7-day": language.text("7 天", "7 days")
            case "1 day": language.text("1 天", "1 day")
            case "Month", "Monthly": language.text("月额度", "Monthly")
            case "Monthly total": language.text("月总额度", "Monthly total")
            case "Monthly Code": language.text("月编程额度", "Monthly Code")
            case "On-demand": language.text("按需额度", "On-demand")
            default: part
            }
        }.joined(separator: " · ")
    }

    private var valueText: String {
        let familyScope =
            row.remainingPercent == nil
            ? language.text("模型家族 · ", "Model family · ")
            : row.unknownCount > 0
                ? language.text("已知模型最低剩余 · ", "Lowest known remaining · ")
                : language.text("家族最低剩余 · ", "Lowest remaining in family · ")
        let scope = row.isShared ? language.text("共享额度 · ", "Shared allowance · ") : row.isFamily ? familyScope : ""
        guard let remaining = row.remainingPercent else {
            let status: String
            switch row.status {
            case .current, .unknown: status = language.text("额度未知", "Allowance unknown")
            case .stale: status = language.text("额度待刷新", "Allowance needs refresh")
            case .expired: status = language.text("重置时间已过，待刷新", "Reset time passed; refresh required")
            case .stopped: status = language.text("未刷新额度", "Allowance is not refreshing")
            }
            return scope + status
        }
        let percentage = remaining.formatted(.number.precision(.fractionLength(0...1))) + "%"
        var value = language.text("剩余 \(percentage)", "\(percentage) left")
        if let amount = row.remainingAmount, let total = row.totalAmount, amount.isFinite, total.isFinite, amount >= 0, total > 0, amount <= total {
            let quantity = amount.formatted(.number.precision(.fractionLength(0...2)))
            value = quantity + " / " + total.formatted(.number.precision(.fractionLength(0...2))) + (row.unit.map { " " + $0 } ?? "") + " · " + value
        }
        return scope + value
    }
}

struct ProviderAccountModelQuotaView: View {
    let models: [ProviderQuotaDisplayRow]
    let summary: [ProviderQuotaDisplayRow]
    let language: WidgetLanguage
    var compact = false
    var quotaIssue: String? = nil
    var sharedInModelMode: [ProviderQuotaDisplayRow] = []
    @State private var everyModel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let shared = sharedInModelMode.isEmpty ? summary.filter(\.isShared) : sharedInModelMode
            let rows = everyModel || summary.isEmpty ? models + shared : summary
            if everyModel || rows.count > 6 {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { row in
                            ProviderQuotaRowView(row: row, language: language, compact: compact)
                        }
                    }
                }.frame(maxHeight: compact ? 260 : 360)
            } else {
                ForEach(rows) { row in
                    ProviderQuotaRowView(row: row, language: language, compact: compact)
                }
            }
            if rows.isEmpty {
                Text(
                    models.isEmpty
                        ? language.text("尚未确认模型目录", "Model catalog not confirmed")
                        : language.text("服务商未提供模型单独额度。", "The provider has not reported individual model allowances.")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if models.count > 1 || (!summary.isEmpty && !models.isEmpty) {
                Button(
                    everyModel
                        ? language.text("按分组显示", "By group")
                        : language.text("每个模型（\(models.count)）", "Every model (\(models.count))")
                ) { everyModel.toggle() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            if quotaIssue != nil {
                Text(language.text("共享额度暂不可用；模型目录仍保留。", "Shared allowance unavailable; the model catalog is retained."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
