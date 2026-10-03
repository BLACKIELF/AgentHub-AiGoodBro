import Foundation

enum HomeResizableSectionID: String, CaseIterable {
    case notices, reset, resetCards, resetAnnouncements, messages, skills, usage, accounts, localCLI, maintenance

    var widthKey: String { "AiGoodBro.home.sectionSize.\(rawValue).width" }
    var heightKey: String { "AiGoodBro.home.sectionSize.\(rawValue).height" }
}

struct HomeSectionSize: Equatable {
    var widthFraction: Double = 1
    /// Zero retains the section's natural height.
    var height: Double = 0

    init(widthFraction: Double = 1, height: Double = 0) {
        self.widthFraction = widthFraction.isFinite && widthFraction > 0 && widthFraction <= 1 ? widthFraction : 1
        self.height = height.isFinite && height > 0 ? min(height, HomeSectionSizing.maximumHeight) : 0
    }

    static func load(_ section: HomeResizableSectionID, from defaults: UserDefaults) -> Self {
        Self(
            widthFraction: defaults.object(forKey: section.widthKey) == nil ? 1 : defaults.double(forKey: section.widthKey),
            height: defaults.double(forKey: section.heightKey))
    }

    func save(_ section: HomeResizableSectionID, to defaults: UserDefaults) {
        defaults.set(widthFraction, forKey: section.widthKey)
        defaults.set(height, forKey: section.heightKey)
    }

    static func reset(_ section: HomeResizableSectionID, in defaults: UserDefaults) {
        defaults.removeObject(forKey: section.widthKey)
        defaults.removeObject(forKey: section.heightKey)
    }
}

enum HomeSectionResizeAxis: Equatable { case width, height, both }

enum HomeSectionSizing {
    static let maximumHeight: Double = 1600
    static let resetSplitKey = "AiGoodBro.home.reset.splitRatio"

    static func width(_ size: HomeSectionSize, available: CGFloat, minimum: CGFloat) -> CGFloat {
        guard available.isFinite, available > 0, minimum.isFinite else { return 0 }
        return min(available, max(min(available, max(0, minimum)), available * CGFloat(size.widthFraction)))
    }

    static func height(_ size: HomeSectionSize, natural: CGFloat, minimum: CGFloat) -> CGFloat {
        guard natural.isFinite, natural >= 0, minimum.isFinite else { return 0 }
        if size.height == 0 { return natural }
        return min(CGFloat(maximumHeight), max(max(0, minimum), CGFloat(size.height)))
    }

    static func resized(
        _ original: HomeSectionSize, startingSize: CGSize, translation: CGSize,
        availableWidth: CGFloat, minimumWidth: CGFloat, minimumHeight: CGFloat,
        axis: HomeSectionResizeAxis
    ) -> HomeSectionSize? {
        guard
            [
                startingSize.width, startingSize.height, translation.width, translation.height,
                availableWidth, minimumWidth, minimumHeight,
            ].allSatisfy(\.isFinite),
            startingSize.width > 0, startingSize.height >= 0, availableWidth > 0
        else { return nil }
        var next = original
        if axis != .height {
            let newWidth = min(availableWidth, max(min(availableWidth, max(0, minimumWidth)), startingSize.width + translation.width))
            next.widthFraction = Double(newWidth / availableWidth)
        }
        if axis != .width {
            next.height = Double(min(CGFloat(maximumHeight), max(max(0, minimumHeight), startingSize.height + translation.height)))
        }
        return next
    }

    static func splitRatio(_ value: Double, availableWidth: CGFloat, minimumWidth: CGFloat = 220) -> Double {
        guard availableWidth.isFinite, availableWidth > 0, minimumWidth.isFinite else { return 0.5 }
        let lower = min(0.5, max(0.25, Double(max(0, minimumWidth) / availableWidth)))
        return min(1 - lower, max(lower, value.isFinite ? value : 0.5))
    }
}
