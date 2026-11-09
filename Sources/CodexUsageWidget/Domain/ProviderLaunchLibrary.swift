import Foundation

/// Local launch choices only. Credentials, endpoints and working directories
/// are resolved by the existing launcher at the time of an explicit launch.
struct ProviderLaunchPreset: Codable, Equatable, Identifiable {
    enum Target: String, Codable, CaseIterable { case codex, native }
    var id: UUID = UUID()
    var name: String
    var provider: AntigravityProxyProvider
    var model: String
    var target: Target
}

struct ProviderLaunchLibrary: Codable, Equatable {
    static let maximumBytes = 65_536
    var version = 1
    var favorites: [String: [String]] = [:]
    var presets: [ProviderLaunchPreset] = []

    static func validModel(_ model: String) -> Bool {
        model.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\\z", options: .regularExpression) != nil
            && hasNoRecognizedSecrets(model)
    }

    private static func hasNoRecognizedSecrets(_ value: String) -> Bool {
        (try? PrivacyPreview.preview(value).replacements) == 0
    }

    var isValid: Bool {
        version == 1 && favorites.count <= AntigravityProxyProvider.allCases.count
            && favorites.allSatisfy { key, models in
                AntigravityProxyProvider(rawValue: key) != nil && models.count <= 32
                    && Set(models).count == models.count && models.allSatisfy(Self.validModel)
            }
            && presets.count <= 32 && Set(presets.map(\.id)).count == presets.count
            && presets.allSatisfy {
                !$0.name.isEmpty && $0.name.count <= 40
                    && $0.name == $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    && $0.name.rangeOfCharacter(from: .controlCharacters) == nil
                    && Self.hasNoRecognizedSecrets($0.name)
                    && Self.validModel($0.model) && ($0.provider != .antigravity || $0.target == .codex)
            }
    }

    func isFavorite(_ model: String, provider: AntigravityProxyProvider) -> Bool {
        favorites[provider.rawValue]?.contains(model) == true
    }

    func togglingFavorite(_ model: String, provider: AntigravityProxyProvider) -> Self? {
        guard Self.validModel(model) else { return nil }
        var updated = self
        var models = favorites[provider.rawValue] ?? []
        if models.contains(model) { models.removeAll { $0 == model } } else { models.append(model) }
        updated.favorites[provider.rawValue] = models.isEmpty ? nil : models
        return updated.isValid ? updated : nil
    }

    func saving(name: String, provider: AntigravityProxyProvider, model: String, target: ProviderLaunchPreset.Target) -> Self? {
        var updated = self
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = updated.presets.firstIndex(where: { $0.provider == provider && $0.name == name && $0.target == target }) {
            updated.presets[index].model = model
        } else {
            updated.presets.append(.init(name: name, provider: provider, model: model, target: target))
        }
        return updated.isValid ? updated : nil
    }

    func removing(_ id: UUID) -> Self {
        var updated = self
        updated.presets.removeAll { $0.id == id }
        return updated
    }

    func merged(with incoming: Self) -> Self? {
        guard isValid, incoming.isValid else { return nil }
        var updated = self
        for (provider, models) in incoming.favorites {
            var combined = updated.favorites[provider] ?? []
            for model in models where !combined.contains(model) { combined.append(model) }
            updated.favorites[provider] = combined
        }
        for preset in incoming.presets {
            if let index = updated.presets.firstIndex(where: { $0.id == preset.id }) {
                updated.presets[index] = preset
            } else {
                updated.presets.append(preset)
            }
        }
        return updated.isValid ? updated : nil
    }

    static func decodeImport(_ data: Data) throws -> Self {
        // Reject foreign provider/key files instead of silently ignoring their
        // credential fields and implying that a provider was imported.
        guard data.count <= maximumBytes,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == Set(["version", "favorites", "presets"]),
            let rows = object["presets"] as? [[String: Any]],
            rows.allSatisfy({ Set($0.keys) == Set(["id", "name", "provider", "model", "target"]) })
        else { throw ImportFailure.invalid }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.isValid else { throw ImportFailure.invalid }
        return result
    }

    func exportData() throws -> Data {
        guard isValid else { throw ImportFailure.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw ImportFailure.invalid }
        return data
    }

    enum ImportFailure: Error { case invalid }
}

struct ProviderLaunchHistory: Codable, Equatable {
    static let storageKey = "CodexManagerNext.providerLaunchLibrary.v1"
    var current = ProviderLaunchLibrary()
    var previous: ProviderLaunchLibrary?

    static func load(_ data: Data?) -> Self {
        guard let data, data.count <= ProviderLaunchLibrary.maximumBytes * 2,
            let value = try? JSONDecoder().decode(Self.self, from: data),
            value.current.isValid, value.previous?.isValid ?? true
        else { return .init() }
        return value
    }

    mutating func apply(_ library: ProviderLaunchLibrary) -> Bool {
        guard library.isValid, library != current else { return false }
        previous = current
        current = library
        return true
    }

    mutating func undo() {
        guard let previous else { return }
        current = previous
        self.previous = nil
    }
}
