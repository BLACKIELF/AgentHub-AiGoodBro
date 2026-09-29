import Foundation

struct HomeDashboardPreferences: Codable, Equatable {
    static let storageKey = "AiGoodBro.home.dashboard.preferences"
    static let defaultHeight = 340
    static let minimumHeight = 260
    static let maximumHeight = 900
    var heatmapStart = ""
    var heatmapMetric = "cost"
    var range = "30"
    var mode = "bars"
    var stackBy = "client"
    var height = Self.defaultHeight

    init() {}

    private enum CodingKeys: String, CodingKey {
        case heatmapStart, heatmapMetric, range, mode, stackBy, height
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        heatmapStart = try values.decodeIfPresent(String.self, forKey: .heatmapStart) ?? ""
        heatmapMetric = try values.decodeIfPresent(String.self, forKey: .heatmapMetric) ?? "cost"
        range = try values.decodeIfPresent(String.self, forKey: .range) ?? "30"
        mode = try values.decodeIfPresent(String.self, forKey: .mode) ?? "bars"
        stackBy = try values.decodeIfPresent(String.self, forKey: .stackBy) ?? "client"
        height = min(
            Self.maximumHeight,
            max(
                Self.minimumHeight,
                try values.decodeIfPresent(Int.self, forKey: .height) ?? Self.defaultHeight))
    }

    var isValid: Bool {
        (heatmapStart.isEmpty || TokenMonitorResponse.validDate(heatmapStart))
            && ["tokens", "cost"].contains(heatmapMetric)
            && ["7", "30", "90", "365", "all"].contains(range)
            && ["bars", "kline"].contains(mode)
            && ["client", "model"].contains(stackBy)
            && (Self.minimumHeight...Self.maximumHeight).contains(height)
    }

    static func load(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return .init() }
        return value
    }
}
