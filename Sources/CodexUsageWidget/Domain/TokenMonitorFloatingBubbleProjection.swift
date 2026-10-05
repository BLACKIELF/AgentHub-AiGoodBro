import Foundation

/// Owner-supplied evidence only. Names must already be safe display aliases.
/// IDs identify the provider, stable account, metric and original source independently.
struct TokenMonitorFloatingBubbleAccount: Equatable {
    var providerID: String
    var providerName: String
    var accountID: String
    var accountName: String
    var isLoggedIn = true
    var metrics: [TokenMonitorFloatingBubbleMetric] = []
    /// Official plan-selected headline for Edge Dock only; other surfaces retain every metric.
    var edgeDockPrimaryMetricID: String? = nil
}

struct TokenMonitorFloatingBubbleMetric: Equatable, Identifiable {
    enum Value: Equatable {
        case unknown
        case percentRemaining(Double)
        /// Credits are never converted into an official quota window.
        case unlimitedCredits
        case text(String)
    }

    var id: String
    var name: String
    var sourceID: String
    var fetchedAt: Date?
    var isStale = false
    var isAvailable = true
    var value: Value = .unknown
    var resetLabel = "—"
    /// Supply only an evidenced, display-safe cost. Absence offers no cost control.
    var costLabel: String? = nil
}

enum TokenMonitorFloatingBubbleProjection {
    static func accounts(
        in sources: [TokenMonitorFloatingBubbleAccount], providerID: String?
    ) -> [TokenMonitorFloatingBubbleAccount] {
        sources.filter { $0.isLoggedIn && $0.providerID == providerID }
    }

    static func resolve(
        preferences: TokenMonitorFloatingBubblePreferences,
        sources: [TokenMonitorFloatingBubbleAccount]
    ) -> TokenMonitorFloatingBubbleSnapshot {
        let providerID = preferences.selectedProviderID ?? ""
        var result = TokenMonitorFloatingBubbleSnapshot(
            providerID: providerID,
            providerName: sources.first { $0.providerID == providerID }?.providerName ?? providerID,
            percentRemaining: nil, resetLabel: "—", costLabel: "—",
            customText: preferences.customText, isUnknown: true, isZero: false,
            accountID: preferences.selectedProfileID, metricID: preferences.selectedMetricID,
            isUnavailable: true
        )
        let matches = accounts(in: sources, providerID: providerID).filter {
            $0.accountID == preferences.selectedProfileID
        }
        // Ambiguous identity is not permission to guess or fall back to another account.
        guard matches.count == 1, let account = matches.first else { return result }
        result.accountName = account.accountName
        let metrics = account.metrics.filter { $0.id == preferences.selectedMetricID }
        guard metrics.count == 1, let metric = metrics.first else { return result }
        result.metricName = metric.name
        result.sourceID = metric.sourceID
        result.fetchedAt = metric.fetchedAt
        result.isStale = metric.isStale
        guard metric.isAvailable, !metric.sourceID.isEmpty else { return result }
        result.isUnavailable = false
        result.resetLabel = metric.resetLabel
        result.hasCost = metric.costLabel != nil
        result.costLabel = metric.costLabel ?? "—"
        switch metric.value {
        case .unknown:
            break
        case .percentRemaining(let percent):
            guard percent.isFinite, (0...100).contains(percent) else { return result }
            result.percentRemaining = percent
            result.isUnknown = false
            result.isZero = percent == 0
        case .unlimitedCredits:
            result.valueLabel = "∞"
            result.isUnknown = false
        case .text(let label):
            guard !label.isEmpty else { return result }
            result.valueLabel = label
            result.isUnknown = false
        }
        return result
    }
}

/// Value-owned editor state; dismissal never commits a draft.
struct TokenMonitorFloatingBubbleDraft {
    var preferences: TokenMonitorFloatingBubblePreferences

    mutating func cancel(saved: TokenMonitorFloatingBubblePreferences) {
        preferences = saved
    }

    func saved(enabled: Bool) -> TokenMonitorFloatingBubblePreferences {
        var value = preferences.normalized()
        value.enabled = enabled
        return value
    }
}

extension TokenMonitorFloatingBubbleSnapshot {
    func displayedPercent(valueMode: String) -> Double? {
        guard !isUnknown, !isUnavailable,
            let percent = percentRemaining, percent.isFinite, (0...100).contains(percent)
        else { return nil }
        return valueMode == "used" ? 100 - percent : percent
    }
}
