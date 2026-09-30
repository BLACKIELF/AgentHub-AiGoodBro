import Foundation

/// Token Monitor's appearance contract: opacity 68, depth 32, system backdrop.
/// Depth changes line/control contrast; it is not a physical blur radius.
struct WorkspaceGlassPreferences: Codable, Equatable {
    static let storageKey = "AiGoodBro.workspace.glass"
    var systemGlass = true
    var opacity = 68
    var depth = 32

    init(systemGlass: Bool = true, opacity: Int = 68, depth: Int = 32) {
        self.systemGlass = systemGlass
        self.opacity = min(100, max(0, opacity))
        self.depth = min(100, max(0, depth))
    }

    private enum CodingKeys: String, CodingKey { case systemGlass, opacity, depth }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(systemGlass: try values.decodeIfPresent(Bool.self, forKey: .systemGlass) ?? true,
                  opacity: try values.decodeIfPresent(Int.self, forKey: .opacity) ?? 68,
                  depth: try values.decodeIfPresent(Int.self, forKey: .depth) ?? 32)
    }

    static func load(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }

    var tintOpacity: Double { max(systemGlass ? 0 : 0.05, Double(min(100, max(0, opacity))) / 100) }
    var lineOpacity: Double { 0.1 + Double(min(100, max(0, depth))) / 100 * 0.09 }
    var controlOpacity: Double { 0.03 + Double(min(100, max(0, depth))) / 100 * 0.045 }
}
