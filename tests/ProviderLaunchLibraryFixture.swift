import Foundation

@main struct ProviderLaunchLibraryFixture {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let empty = ProviderLaunchLibrary()
        check(empty.isValid, "empty library")
        check(ProviderLaunchHistory.load(nil).current == empty, "missing preferences stay empty")
        let favorite = empty.togglingFavorite("fixture-model", provider: .claude)!
        check(favorite.isFavorite("fixture-model", provider: .claude), "favorite retained")
        check(!favorite.isFavorite("fixture-model", provider: .kimi), "provider scoped")
        check(favorite.togglingFavorite("fixture-model", provider: .claude) == empty, "toggle removes empty bucket")
        check(empty.togglingFavorite("model; echo bad", provider: .claude) == nil, "shell metacharacters rejected")
        check(empty.togglingFavorite("model\n", provider: .claude) == nil, "trailing newline rejected")
        let saved = favorite.saving(name: "  专注  ", provider: .claude, model: "fixture-model", target: .native)!
        check(saved.presets[0].name == "专注", "name trimmed")
        let changed = saved.saving(name: "专注", provider: .claude, model: "other-model", target: .native)!
        check(changed.presets.count == 1 && changed.presets[0].id == saved.presets[0].id, "same name updates same preset")
        check(changed.presets[0].model == "other-model", "model updated")
        check(empty.saving(name: "x", provider: .antigravity, model: "fixture-model", target: .native) == nil, "unsupported native model selection refused")
        check(empty.saving(name: "a\nb", provider: .kimi, model: "fixture-model", target: .native) == nil, "multiline name refused")
        for name in ["synthetic@example.invalid", "token=synthetic-value", "/Users/fixture-only/project"] {
            check(empty.saving(name: name, provider: .kimi, model: "fixture-model", target: .native) == nil, "sensitive label refused")
            var unsafe = saved
            unsafe.presets[0].name = name
            do { _ = try ProviderLaunchLibrary.decodeImport(JSONEncoder().encode(unsafe)); preconditionFailure("sensitive import accepted") } catch { checks += 1 }
        }
        check(!ProviderLaunchLibrary.validModel("sk-" + String(repeating: "x", count: 24)), "key-like model rejected")
        let exported = try saved.exportData()
        let imported = try ProviderLaunchLibrary.decodeImport(exported)
        check(imported == saved, "round trip")
        check(!String(decoding: exported, as: UTF8.self).contains("apiKey"), "no credential fields in schema")
        let merged = saved.merged(with: changed)!
        check(merged == changed, "import updates matching UUID once")
        check(merged.merged(with: changed) == merged, "reimport idempotent")
        var history = ProviderLaunchHistory()
        check(history.apply(saved), "apply")
        check(!history.apply(saved), "no-op import does not overwrite undo")
        check(history.previous == empty, "original retained")
        let restored = ProviderLaunchHistory.load(try JSONEncoder().encode(history))
        check(restored == history, "undo survives relaunch")
        history.undo()
        check(history.current == empty && history.previous == nil, "one-step undo")
        check(saved.removing(saved.presets[0].id).presets.isEmpty, "remove only selected preset")
        var duplicate = saved
        duplicate.presets.append(saved.presets[0])
        check(!duplicate.isValid, "duplicate id refused")
        var tooMany = empty
        tooMany.favorites["claude"] = (0..<33).map { "model-\($0)" }
        check(!tooMany.isValid, "favorites bounded")
        var full = empty
        for i in 0..<32 { full = full.saving(name: "Preset \(i)", provider: .kimi, model: "model-\(i)", target: .native)! }
        check(full.saving(name: "Overflow", provider: .kimi, model: "model-extra", target: .native) == nil, "presets bounded")
        check(full.saving(name: "Preset 0", provider: .kimi, model: "replacement", target: .native) != nil, "edit remains possible at limit")
        let invalid: [Data] = [
            Data(#"{"version":1,"favorites":{},"presets":[],"apiKey":"fixture-only"}"#.utf8),
            Data(#"{"version":2,"favorites":{},"presets":[]}"#.utf8),
            Data(#"{"version":1,"favorites":{"unknown":["model"]},"presets":[]}"#.utf8),
            Data(repeating: 32, count: ProviderLaunchLibrary.maximumBytes + 1),
            try JSONEncoder().encode(duplicate),
        ]
        for data in invalid {
            do { _ = try ProviderLaunchLibrary.decodeImport(data); preconditionFailure("invalid import accepted") } catch { checks += 1 }
        }
        print("PASS: \(checks) launch-library assertions; no network, credentials, processes or user defaults accessed")
    }
}
