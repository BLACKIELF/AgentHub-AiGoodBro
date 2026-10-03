import Foundation

enum HomeResetMessageOrder: String, CaseIterable {
    case cardsFirst, announcementsFirst
    static let storageKey = "AiGoodBro.home.resetMessageOrder"

    var blocks: [String] { self == .cardsFirst ? ["cards", "announcements"] : ["announcements", "cards"] }
    var swapped: Self { self == .cardsFirst ? .announcementsFirst : .cardsFirst }

    static func dropTarget(source: String, at point: CGPoint, frames: [String: CGRect]) -> String? {
        guard ["cards", "announcements"].contains(source), point.x.isFinite, point.y.isFinite else { return nil }
        let target = source == "cards" ? "announcements" : "cards"
        guard let frame = frames[target], frame.width > 0, frame.height > 0,
            [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite), frame.contains(point)
        else { return nil }
        return target
    }
}
