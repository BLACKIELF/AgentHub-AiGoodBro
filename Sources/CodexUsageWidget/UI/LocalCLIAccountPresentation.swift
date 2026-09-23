import Foundation

/// Display only verified provider facts. Login, quotas and purchased credit are
/// separate observations and must not be inferred from one another.
enum LocalCLIAccountPresentation {
    static func balanceTitle(kind: LocalCLIKind, language: WidgetLanguage) -> String {
        kind == .grok ? language.text("购入余额", "Purchased balance") : language.text("余额", "Balance")
    }

    static func balanceText(kind: LocalCLIKind, result: LocalCLIQuotaResult, language: WidgetLanguage) -> String? {
        guard let balance = result.balance, balance.isFinite else { return nil }
        let currency = result.balanceCurrency ?? (kind == .grok ? "USD" : nil)
        return balance.formatted(.number.precision(.fractionLength(0...4)).locale(language.locale))
            + (currency.map { " " + $0 } ?? "")
    }

    static func quotaExplanation(kind: LocalCLIKind, result: LocalCLIQuotaResult?, language: WidgetLanguage) -> String? {
        guard let code = result?.messageCode else { return nil }
        switch code {
        case "local_cli_usage_not_reported":
            return language.text(
                "官方未提供已用和剩余百分比；已返回的余额与重置时间仍会显示。",
                "The provider did not report used or remaining percentages. Reported balances and reset times are still shown.")
        case "local_cli_antigravity_open_app":
            return language.text("请先打开官方 Antigravity 并登录，再刷新；当前尚无可核实的运行账号。", "Open the official Antigravity app and sign in, then refresh. No running account can be verified yet.")
        case "local_cli_antigravity_no_quota":
            return language.text("已识别当前 Antigravity 账号，但官方尚未返回可用额度。", "The current Antigravity account was recognized, but no usable quota was returned.")
        case "local_cli_antigravity_live_unavailable":
            return language.text("Antigravity 正在运行，但未读到当前账号额度，请稍后刷新。", "Antigravity is running, but the current account's quota could not be read. Refresh again shortly.")
        case "local_cli_antigravity_account_changed":
            return language.text("读取期间 Antigravity 账号发生变化，未合并不同账号的额度，请重新刷新。", "The Antigravity account changed during the read. Quotas were not merged across accounts; refresh again.")
        case "local_cli_antigravity_cache_unavailable":
            return language.text("所选 Antigravity 配置的额度缓存不可读或格式不匹配，请在对应官方应用中更新后再刷新。", "The selected Antigravity quota cache is unreadable or incompatible. Update it in the matching official app, then refresh.")
        case "local_cli_antigravity_linked_cache_only":
            return language.text("关联账号只读取其已保存的额度记录；请选择包含官方应用登录数据的独立配置文件夹。", "Linked accounts only read saved quota. Select a separate configuration folder containing the official app's sign-in data.")
        case "local_cli_antigravity_cached_quota":
            return language.text("这是 Antigravity IDE 的历史额度记录；额度记录时间未提供。请打开 Antigravity 刷新核实。", "This is historical Antigravity IDE quota; its observation time was not provided. Open Antigravity and refresh to verify.")
        case "local_cli_opencode_go_not_connected", "local_cli_upstream_provider_missing", "local_cli_upstream_unsupported_go_plan":
            return language.text(
                "未连接 OpenCode Go 额度；其他服务商的登录状态和余额需分别核对。",
                "OpenCode Go quota is not connected. Other providers' sign-in and balances are separate.")
        case "local_cli_gemini_oauth_personal_required":
            return language.text(
                "当前使用 API Key 或其他认证方式，不能读取 Google 个人订阅额度。",
                "This authentication uses an API key or another method; Google personal subscription quota is unavailable.")
        case "local_cli_mimo_native_quota_unsupported":
            return language.text("已识别 MiMo 配置，当前未提供可读取的官方额度接口。", "MiMo configuration is recognized; a readable official quota endpoint is not available.")
        case "local_cli_zcode_native_quota_unsupported", "local_cli_zcode_coding_plan_unsupported":
            return language.text("当前配置未提供可读取的 Coding Plan 额度；桌面订阅状态需在官方应用内查看。", "This configuration has no readable Coding Plan quota. Check the desktop subscription in the official app.")
        case "local_cli_authorization_unverified":
            return language.text("服务商未确认额度查询权限，请在官方账号页核对；这不表示账号已退出。", "The provider did not confirm quota access. Check the official account page; this does not mean the account signed out.")
        case "local_cli_invalid_credentials":
            return language.text("已保存的认证无法通过额度校验，请在官方登录流程中更新后刷新。", "Saved authentication did not pass quota validation. Update it through the official sign-in flow, then refresh.")
        case "local_cli_keychain_unavailable":
            return language.text("暂时无法读取登录钥匙串，请允许访问后刷新。", "Sign-in Keychain data is unavailable. Allow access, then refresh.")
        case "local_cli_upstream_auth_changed", "local_cli_upstream_target_changed", "local_cli_upstream_identity_mismatch":
            return language.text("查询期间账号配置发生变化，已停止合并额度，请刷新当前账号。", "Account configuration changed during the read. Quota was not merged; refresh the current account.")
        case "local_cli_upstream_invalid_auth_file":
            return language.text("已关联的认证配置无法安全读取，请重新选择有效的官方配置。", "The linked authentication cannot be read safely. Select a valid official configuration again.")
        case "local_cli_invalid_response", "local_cli_upstream_invalid_response", "local_cli_upstream_malformed_bundle", "local_cli_upstream_ambiguous_json", "local_cli_upstream_body_limit":
            return language.text("服务商返回的数据暂时无法识别，未把未知额度记为 0。", "The provider response could not be interpreted. Unknown quota is not recorded as zero.")
        case "local_cli_upstream_timeout", "local_cli_upstream_transport_failed", "local_cli_upstream_collection_failed":
            return language.text("额度请求超时或连接失败，请检查网络后刷新。", "The quota request timed out or could not connect. Check the network and refresh.")
        case "local_cli_upstream_network_disabled":
            return language.text("本次额度读取未启用网络访问，登录配置仍会保留。", "Network access was disabled for this quota read. Saved sign-in configuration is preserved.")
        case "local_cli_upstream_endpoint_rejected", "local_cli_upstream_redirect_rejected":
            return language.text("额度接口地址未通过验证，已停止查询，请在官方账号页核对。", "The quota endpoint could not be verified. The request was stopped; check the official account page.")
        case "local_cli_needs_login", "local_cli_upstream_auth_missing", "local_cli_upstream_unauthorized":
            return kind.isDesktopApplication
                ? language.text("请在官方桌面应用中登录，再刷新这里的账号与额度。", "Sign in through the official desktop app, then refresh the account and quota here.")
                : language.text("当前配置尚无可用登录凭据，请登录或关联已登录的配置。", "This configuration has no usable sign-in credentials. Sign in or link an authenticated configuration.")
        case "local_cli_unsupported", "local_cli_adapter_not_owned":
            return language.text("当前平台尚未提供可读取的额度，不影响其官方应用的登录。", "Readable quota is not available for this platform. Its official app sign-in is separate.")
        default:
            return nil
        }
    }
}
