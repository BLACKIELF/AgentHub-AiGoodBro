import SwiftUI

/// Eager native layout keeps every account in full-content screenshots, including offscreen rows.
/// Cards align within each row. A detailed card must not inflate every other
/// row or separate a short card's identity from its quota and controls.
struct AccountCardGridLayout: Layout {
    /// Account cards contain identity, model disclosure, quota windows, and
    /// primary actions. The old 250pt minimum fit three cards at the 822pt
    /// window and truncated those controls. Add columns only when this
    /// natural width fits.
    var minimumWidth: CGFloat = Self.minimumCardWidth
    static let minimumCardWidth: CGFloat = 320
    static let spacing: CGFloat = 10

    /// The resolved dimensions for one complete grid pass.
    ///
    /// Keeping this value independent from `Layout.Subviews` makes the sizing
    /// contract testable without rendering a window.
    struct Metrics: Equatable {
        let width: CGFloat
        let columns: Int
        let rows: Int
        let cardWidth: CGFloat
        let rowHeights: [CGFloat]
        let rowOffsets: [CGFloat]
        let totalHeight: CGFloat
        let itemCount: Int
        let spacing: CGFloat

        var size: CGSize {
            CGSize(width: width, height: totalHeight)
        }

        /// Returns the origin-relative frame used by `placeSubviews`.
        /// Invalid indexes are ignored so synthetic checks cannot accidentally
        /// manufacture a placement outside the measured collection.
        func frame(for index: Int) -> CGRect? {
            guard index >= 0, index < itemCount else { return nil }
            let row = index / columns
            let column = index % columns
            return CGRect(
                x: CGFloat(column) * (cardWidth + spacing),
                y: rowOffsets[row],
                width: cardWidth,
                height: rowHeights[row]
            )
        }
    }

    static func columnCount(width: CGFloat, itemCount: Int, minimumWidth: CGFloat = minimumCardWidth) -> Int {
        guard width.isFinite, width > 0, itemCount > 0 else { return 1 }
        let available = floor((width + spacing) / (max(260, minimumWidth) + spacing))
        // A pathological but valid CGFloat can overflow the division or be
        // outside Int's conversion range. Returning all requested columns is
        // safe in that case and keeps this pure helper trap-free.
        guard available.isFinite, available < CGFloat(Int.max) else { return itemCount }
        return max(1, min(itemCount, Int(available)))
    }

    static func sharedCardHeight(_ heights: [CGFloat]) -> CGFloat {
        heights.reduce(0) { current, rawHeight in
            guard rawHeight.isFinite else { return current }
            return max(current, max(0, rawHeight))
        }
    }

    static func rowCount(itemCount: Int, columns: Int) -> Int {
        guard itemCount > 0, columns > 0 else { return 0 }
        return (itemCount - 1) / columns + 1
    }

    /// Computes equal widths and the natural maximum height of each row.
    ///
    /// `intrinsicHeights` are the unconstrained heights returned by each
    /// subview for the resolved card width. Invalid heights are treated as
    /// unavailable rather than allowing NaN/infinity to poison the whole grid.
    static func metrics(width: CGFloat, intrinsicHeights: [CGFloat], minimumWidth: CGFloat = minimumCardWidth) -> Metrics {
        let resolvedWidth = Self.resolvedWidth(width)
        let columns = columnCount(width: resolvedWidth, itemCount: intrinsicHeights.count, minimumWidth: minimumWidth)
        let cardWidth = Self.cardWidth(width: resolvedWidth, columns: columns)
        let rows = rowCount(itemCount: intrinsicHeights.count, columns: columns)
        let rowHeights = (0..<rows).map { row in
            sharedCardHeight(Array(intrinsicHeights[(row * columns)..<min((row + 1) * columns, intrinsicHeights.count)]))
        }
        var nextY: CGFloat = 0
        let rowOffsets = rowHeights.map { height in
            let offset = nextY
            nextY += height + spacing
            return offset
        }
        let totalHeight = rows == 0 ? 0 : nextY - spacing
        return Metrics(
            width: resolvedWidth,
            columns: columns,
            rows: rows,
            cardWidth: cardWidth,
            rowHeights: rowHeights,
            rowOffsets: rowOffsets,
            totalHeight: totalHeight,
            itemCount: intrinsicHeights.count,
            spacing: spacing
        )
    }

    private static func resolvedWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite, width >= 0 else {
            return max(0, CodexAccountManagerView.defaultWidth - 36)
        }
        return width
    }

    private static func cardWidth(width: CGFloat, columns: Int) -> CGFloat {
        guard width.isFinite, width >= 0, columns > 0 else { return 0 }
        let result = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        guard result.isFinite else { return 0 }
        return max(0, result)
    }

    private func measurements(width: CGFloat, subviews: Subviews) -> Metrics {
        let resolvedWidth = Self.resolvedWidth(width)
        let columns = Self.columnCount(width: resolvedWidth, itemCount: subviews.count, minimumWidth: minimumWidth)
        let cardWidth = Self.cardWidth(width: resolvedWidth, columns: columns)
        var heights: [CGFloat] = []
        heights.reserveCapacity(subviews.count)
        for index in subviews.indices {
            heights.append(subviews[index].sizeThatFits(.init(width: cardWidth, height: nil)).height)
        }
        return Self.metrics(width: resolvedWidth, intrinsicHeights: heights, minimumWidth: minimumWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CodexAccountManagerView.defaultWidth - 36
        return measurements(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = measurements(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            guard let frame = measured.frame(for: index) else { continue }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: .init(width: frame.width, height: frame.height)
            )
        }
    }

    static func selfTest() -> Bool {
        // Synthetic content-height samples stand in for a long account name,
        // 0%, 100%, and unknown quota cards while keeping the check renderer-free.
        let heights: [CGFloat] = [148, 112, 116, 96, 132, 104, 108, 112, 100]
        let shared = sharedCardHeight(heights)
        guard columnCount(width: 870, itemCount: 9, minimumWidth: 280) == 3,
            columnCount(width: 870, itemCount: 9, minimumWidth: 380) == 2,
            columnCount(width: 720, itemCount: heights.count) == 2,
            columnCount(width: 980, itemCount: heights.count) == 3,
            columnCount(width: 784, itemCount: 9) == 2,
            columnCount(width: 944, itemCount: 9) == 2,
            columnCount(width: 1_064, itemCount: 9) == 3,
            columnCount(width: 1_404, itemCount: 9) == 4,
            columnCount(width: .infinity, itemCount: 9) == 1,
            shared == 148,
            sharedCardHeight([]) == 0,
            rowCount(itemCount: 9, columns: 3) == 3,
            rowCount(itemCount: 0, columns: 3) == 0
        else {
            print("account card grid layout self-test failed")
            return false
        }

        for width in [CGFloat(720), 980] {
            let measured = metrics(width: width, intrinsicHeights: heights)
            guard measured.rows >= 3,
                measured.cardWidth > 0,
                measured.rowHeights.max() == shared,
                measured.totalHeight == measured.rowHeights.reduce(0, +)
                    + CGFloat(measured.rows - 1) * spacing,
                measured.frame(for: -1) == nil,
                measured.frame(for: heights.count) == nil
            else {
                print("account card grid layout self-test failed: invalid \(Int(width))pt metrics")
                return false
            }

            let frames = heights.indices.compactMap { measured.frame(for: $0) }
            guard frames.count == heights.count,
                frames.enumerated().allSatisfy({ index, frame in
                    frame.width == measured.cardWidth && frame.height == measured.rowHeights[index / measured.columns]
                        && frame.height >= heights[index]
                }),
                Set(frames.map(\.minY)).count == measured.rows,
                frames.last?.maxY == measured.totalHeight,
                measured.totalHeight < shared * CGFloat(measured.rows) + CGFloat(measured.rows - 1) * spacing,
                frames.enumerated().allSatisfy({ index, frame in
                    frames.dropFirst(index + 1).allSatisfy { !frame.intersects($0) }
                })
            else {
                print("account card grid layout self-test failed: invalid row alignment at \(Int(width))pt")
                return false
            }
        }

        guard sharedCardHeight([.nan, -.infinity, 0, 100, .infinity]) == 100,
            metrics(width: .nan, intrinsicHeights: []).size.width == CodexAccountManagerView.defaultWidth - 36,
            metrics(width: 980, intrinsicHeights: []).totalHeight == 0
        else {
            print("account card grid layout self-test failed: invalid-value handling")
            return false
        }
        print("account card grid layout self-test passed")
        return true
    }
}

// One saved control applies to every provider without scaling text or hit targets.
enum AccountCardDensity: String, CaseIterable {
    case compact, standard, spacious
    var minimumWidth: CGFloat { self == .compact ? 280 : self == .standard ? 320 : 380 }
    var padding: CGFloat { self == .compact ? 10 : self == .standard ? 14 : 18 }
    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .compact: language.text("紧凑", "Compact")
        case .standard: language.text("标准", "Standard")
        case .spacious: language.text("宽松", "Spacious")
        }
    }
}
private struct AccountCardDensityKey: EnvironmentKey { static let defaultValue = AccountCardDensity.compact }
extension EnvironmentValues {
    var accountCardDensity: AccountCardDensity {
        get { self[AccountCardDensityKey.self] }
        set { self[AccountCardDensityKey.self] = newValue }
    }
}
struct AccountCardDensityPicker: View {
    @AppStorage("AiGoodBro.accountCardDensity") private var saved = AccountCardDensity.compact.rawValue
    @Environment(\.widgetLanguage) private var language
    var body: some View {
        Picker(language.text("卡片大小", "Card size"), selection: $saved) {
            ForEach(AccountCardDensity.allCases, id: \.rawValue) { density in
                Text(density.title(language)).tag(density.rawValue)
            }
        }.fixedSize().controlSize(.small)
            .help(language.text("统一调整所有账号卡片的宽度与间距", "Adjust width and spacing for all account cards"))
    }
}
