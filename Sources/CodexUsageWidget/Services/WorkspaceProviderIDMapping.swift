import Foundation

/// 工作区（派单/导航 UI 侧）ID 与上游额度目录 providerId 的映射
///（CONTRACT.md §1.3、§15）。Grok 的 UI 以 `codex` + `LocalCLIKind.rawValue`
/// 标识工作区入口；数据/额度层使用 24 个目录 providerId。两套 ID 的换算
/// 只经此表，避免字符串散落。
///
/// 映射依据（上游 clientCatalog/limitProviders @2f60827）：
/// - 本地 client 与 provider 同 ID 直映，例外 `micode→mimo`、`zcode→zai`、
///   `qodercn→qoder`；
/// - 工作区枚举名是 camelCase（claudeCode/openCode/workBuddy），目录 ID
///   是小写无驼峰（claude/opencode/workbuddy）；
/// - `gemini` 是工作区能力，上游无对应额度 client（非 catalog 仅标签），
///   映射为 nil：工作区可见，额度目录不提供。
enum WorkspaceProviderIDMapping {
    /// LocalCLIKind.rawValue → 目录 providerId。nil = 工作区能力无目录数据。
    static func catalogProviderID(forWorkspaceKindID workspaceKindID: String) -> String? {
        switch workspaceKindID.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "codex": return "codex"
        case "claudeCode": return "claude"
        case "grok": return "grok"
        case "openCode": return "opencode"
        case "trae": return "trae"
        case "workBuddy": return "workbuddy"
        case "kimi": return "kimi"
        case "mimo": return "mimo"
        case "zcode": return "zai"
        case "antigravity": return "antigravity"
        default: return nil
        }
    }

    /// 目录 providerId → 工作区 kind ID。nil = 目录平台暂无工作区派单能力
    /// （如 cursor/copilot/zed/deepseek 等 24 目录中的其余项）。
    static func workspaceKindID(forCatalogProviderID providerId: String) -> String? {
        let key = providerId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "codex": return "codex"
        case "claude": return "claudeCode"
        case "grok": return "grok"
        case "opencode": return "openCode"
        case "trae": return "trae"
        case "workbuddy": return "workBuddy"
        case "kimi": return "kimi"
        case "mimo": return "mimo"
        case "zai": return "zcode"
        case "antigravity": return "antigravity"
        default: return nil
        }
    }
}
