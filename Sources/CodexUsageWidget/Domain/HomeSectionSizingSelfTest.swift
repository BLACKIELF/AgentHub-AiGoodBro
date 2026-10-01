import Foundation

enum HomeSectionSizingSelfTest {
    static func run() -> Bool {
        let suite = "AiGoodBro.section-size-self-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
        let original = HomeSectionSize()
        let start = CGSize(width: 1000, height: 200)
        func resize(_ axis: HomeSectionResizeAxis, _ delta: CGSize) -> HomeSectionSize? {
            HomeSectionSizing.resized(original, startingSize: start, translation: delta, availableWidth: 1000, minimumWidth: 300, minimumHeight: 72, axis: axis)
        }
        check(HomeSectionSizing.width(original, available: 1000, minimum: 300) == 1000, "natural-width")
        check(HomeSectionSizing.height(original, natural: 125, minimum: 72) == 125, "natural-height")
        check(HomeSectionSize(widthFraction: .nan, height: -.infinity) == original, "invalid-preference")
        check(HomeSectionSize(widthFraction: 2, height: -1) == original, "out-of-range-preference")
        check(HomeSectionSize(height: 9999).height == HomeSectionSizing.maximumHeight, "maximum-stored-height")
        let both = resize(.both, CGSize(width: -200, height: 80))
        check(both == HomeSectionSize(widthFraction: 0.8, height: 280), "two-dimensional-resize")
        check(resize(.width, CGSize(width: -200, height: 80)) == HomeSectionSize(widthFraction: 0.8), "width-preserves-auto-height")
        check(resize(.height, CGSize(width: -200, height: 80)) == HomeSectionSize(height: 280), "height-preserves-width")
        check(resize(.both, CGSize(width: -9999, height: -9999)) == HomeSectionSize(widthFraction: 0.3, height: 72), "minimum-bounds")
        check(resize(.both, CGSize(width: 9999, height: 9999)) == HomeSectionSize(height: 1600), "maximum-bounds")
        check(resize(.both, CGSize(width: CGFloat.nan, height: 0)) == nil, "invalid-pointer-rejected")
        check(
            HomeSectionSizing.resized(original, startingSize: .zero, translation: .zero, availableWidth: 0, minimumWidth: 300, minimumHeight: 72, axis: .both) == nil,
            "unmeasured-container-rejected")
        check(HomeSectionSizing.width(.init(widthFraction: 0.6), available: 400, minimum: 300) == 300, "narrow-window-minimum")
        check(HomeSectionSizing.width(.init(widthFraction: 0.6), available: 200, minimum: 300) == 200, "minimum-fits-window")
        check(HomeSectionSizing.width(.init(widthFraction: 0.6), available: 1200, minimum: 300) == 720, "relative-width-follows-window")
        check(HomeSectionSizing.splitRatio(.nan, availableWidth: 1000) == 0.5, "invalid-split")
        check(HomeSectionSizing.splitRatio(0.9, availableWidth: 1000) == 0.75, "split-upper-bound")
        check(HomeSectionSizing.splitRatio(0.1, availableWidth: 1000) == 0.25, "split-lower-bound")
        check(HomeSectionSizing.splitRatio(0.1, availableWidth: 600) * 600 >= 220 - 0.000_001, "split-preserves-readable-width")
        check(HomeSectionSizing.splitRatio(0.9, availableWidth: 200) == 0.5, "split-too-narrow")
        let cycleWidths: [CGFloat] = [1240, 500, 900]
        let cycleLeftWidths: [CGFloat] = [429.8, 220, 310.8]
        for (width, expectedLeft) in zip(cycleWidths, cycleLeftWidths) {
            let frames = ResetMessageColumnsLayout.frames(width: width, splitRatio: 0.35, count: 3) { _, _ in 180 }
            check(abs(frames[0].width - expectedLeft) < 0.000_001, "reset-columns-width-cycle-\(Int(width))")
            check(abs(frames[2].maxX - width) < 0.000_001, "reset-columns-fill-current-proposal-\(Int(width))")
        }
        for width: CGFloat in [1240, 500, 900, 420, 12, 1] {
            for ratio: Double in [-100, 0.35, 0.5, 0.65, 100, .nan, .infinity, -.infinity] {
                var measuredWidths: [CGFloat] = []
                let frames = ResetMessageColumnsLayout.frames(width: width, splitRatio: ratio, count: 3) { index, proposedWidth in
                    measuredWidths.append(proposedWidth)
                    return index == 1 ? 40 : 180
                }
                let label = "reset-columns-\(Int(width))-\(ratio)"
                check(frames.count == 3 && measuredWidths == frames.map(\.width), label + "-measures-each-column-width")
                check(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= width + 0.000_001 && $0.minY == 0 && $0.width >= 0 }, label + "-bounded-horizontal")
                check(abs(frames[0].maxX - frames[1].minX) < 0.000_001 && abs(frames[1].maxX - frames[2].minX) < 0.000_001, label + "-contiguous")
                check(abs(frames[1].width - min(12, width)) < 0.000_001 && abs(frames[2].maxX - width) < 0.000_001, label + "-divider-and-total-width")
                if width >= 452 {
                    check(frames[0].width >= 220 - 0.000_001 && frames[2].width >= 220 - 0.000_001, label + "-readable-columns")
                }
            }
        }
        let invalidWidthFrames = ResetMessageColumnsLayout.frames(width: .nan, splitRatio: 0.5, count: 3) { _, _ in .infinity }
        check(invalidWidthFrames.allSatisfy { $0.width.isFinite && $0.height == 0 }, "reset-columns-invalid-measurement")
        for heights: [CGFloat] in [[72, 24, 138], [240, 24, 90], [72, 900, 96], [40, 24, 64]] {
            let frames = ResetMessageColumnsLayout.frames(width: 900, splitRatio: 0.35, count: 3) { index, _ in heights[index] }
            check(frames.allSatisfy { $0.height == max(heights[0], heights[2]) }, "reset-columns-current-shared-height-\(heights)")
        }
        for width: CGFloat in [1240, 500, 900] {
            let frames = ResetMessageColumnsLayout.frames(width: width, splitRatio: 0.35, count: 3) { index, columnWidth in
                index == 1 ? 24 : ceil((index == 0 ? 30_000.0 : 50_000.0) / max(1, columnWidth))
            }
            check(frames[0].height == frames[2].height && frames[1].height == frames[0].height, "reset-columns-wrap-equal-height-\(Int(width))")
        }
        for count in [0, 1, 2, 4] {
            let frames = ResetMessageColumnsLayout.frames(width: 500, splitRatio: 0.5, count: count) { _, _ in 100 }
            check(frames.count == count && frames.allSatisfy { $0.minX >= 0 && $0.maxX <= 500 }, "reset-columns-unexpected-child-count-\(count)")
        }
        for section in HomeResizableSectionID.allCases {
            check(HomeSectionSize.load(section, from: defaults) == original, "default-\(section.rawValue)")
            HomeSectionSize(widthFraction: 0.65, height: 280).save(section, to: defaults)
            guard let reloaded = UserDefaults(suiteName: suite) else { return false }
            check(HomeSectionSize.load(section, from: reloaded) == .init(widthFraction: 0.65, height: 280), "persist-\(section.rawValue)")
            HomeSectionSize.reset(section, in: defaults)
            check(HomeSectionSize.load(section, from: defaults) == original, "reset-\(section.rawValue)")
        }
        check(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("AiGoodBro.home.sectionSize.") }.isEmpty, "reset-removes-only-sizing-keys")
        if !failures.isEmpty {
            print("Home section sizing failed: " + failures.joined(separator: ", "))
        } else {
            print("Home section sizing: bounds, axes, responsive widths, proposal-driven reset columns, split and independent saved sections passed")
        }
        return failures.isEmpty
    }
}
