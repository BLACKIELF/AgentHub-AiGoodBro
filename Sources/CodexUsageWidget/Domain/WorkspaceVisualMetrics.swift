import SwiftUI

/// Single source for onboarding-modes spacing, type and quota-track geometry.
/// Provider cards must not invent a second title size or track thickness.
enum WorkspaceVisualMetrics {
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
    }

    static let cardPadding: CGFloat = 10
    static let cardCorner: CGFloat = 16
    static let trackThickness: CGFloat = 3
    static let legacyTrackThickness: CGFloat = 8
    static let reservedQuotaSlots = 2
    static let titleSize: CGFloat = 15
    static let bodySize: CGFloat = 13
    static let metaSize: CGFloat = 11
    static let valueSize: CGFloat = 22
    static let compactValueSize: CGFloat = 18

    static func titleFont() -> Font { .system(size: titleSize, weight: .semibold) }
    static func bodyFont() -> Font { .system(size: bodySize, weight: .regular) }
    static func metaFont() -> Font { .system(size: metaSize, weight: .regular) }
    static func valueFont(compact: Bool = false) -> Font {
        .system(size: compact ? compactValueSize : valueSize, weight: .semibold, design: .rounded).monospacedDigit()
    }
}

enum QuotaRowState: Equatable {
    case value(Double)
    case loading
    case unknown
    case error
    case expired
    case empty

    static func from(percent: Double?, loading: Bool = false, expired: Bool = false, failed: Bool = false) -> Self {
        if loading { return .loading }
        if failed { return .error }
        if expired { return .expired }
        guard let percent, percent.isFinite else { return .unknown }
        return .value(max(0, min(100, percent)))
    }

    var fillFraction: CGFloat? {
        if case .value(let percent) = self { return CGFloat(percent / 100) }
        return nil
    }

    func percentText() -> String {
        switch self {
        case .value(let percent): return QuotaAvailabilityPresentation.percentText(percent)
        case .loading, .unknown, .error, .expired, .empty: return "—"
        }
    }

    func accessibilityValue(_ language: WidgetLanguage) -> String {
        switch self {
        case .value(let percent): return QuotaAvailabilityPresentation.percentText(percent)
        case .loading: return language.text("正在读取", "Loading")
        case .unknown: return language.text("未知", "Unknown")
        case .error: return language.text("读取失败", "Could not read")
        case .expired: return language.text("已过期", "Expired")
        case .empty: return language.text("无此窗口", "No window")
        }
    }
}

struct QuotaWindowModel: Identifiable, Equatable {
    var id: String
    var label: String
    var state: QuotaRowState
    var footnote: String
}

struct AccountQuotaCardModel: Identifiable, Equatable {
    var id: String
    var providerID: String
    var displayName: String
    var windows: [QuotaWindowModel]
    var resetCardCount: Int?
    var refreshedLabel: String
    var statusLabel: String
    var isExample: Bool
}

enum AccountQuotaCardSize: Equatable {
    case compactTile
    case standard
}
