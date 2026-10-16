# AiGoodBro 2.5.2（147）

1017v1 · 2026-10-17 · macOS 13+ / Apple Silicon ARM64

相较 2.5.1（146），本版包含四项改进：

- **反代按钮**：反代面板的操作按钮采用统一蓝色强调样式，包含调序和重置卡入口。
- **OAuth 失效显示**：最新刷新确认登录失效时，队列优先显示“登录已过期”，旧额度标为“上次快照”。重新登录并成功刷新后，重新评估账号状态。
- **建连前有界重试**：本地控制连接尚未建立时，短暂连接失败在原等待期限内最多尝试三次；连接建立后的超时或断流沿用原安全处理，不重放已发送请求。
- **诊断分类**：以固定码区分连接未建立、登记状态无效、登记读写失败和控制通道忙碌，不记录原始错误、路径、账号或请求内容。未知控制结果继续保留占用并停止反代。

覆盖安装沿用现有安装引导和配置保留机制。已有账号、主题、反代规则、通知连接和自动使用授权继续保留；查看更新介绍不会自动开启功能或完成安装引导。

本版不自动修复失效登录；登录失效仍需用户重新登录并刷新。历史反代断开的现场根因尚未确认，本次连接重试和诊断改进不构成已根治中断的结论。本机已完成整包构建、签名核验、覆盖安装及界面检查；这些结果不替代长期真实调用或失效账号重新登录后的验收。

## English

**2.5.2 (147), release 1017v1**, updates four areas from 2.5.1: consistent blue proxy action buttons; current OAuth invalidation shown ahead of older quota snapshots; at most three connection attempts before a local control connection is established, within the existing deadline; and fixed diagnostic codes separating transport, registry state, registry access and control contention failures.

Connected requests are not replayed. Unknown control outcomes keep the existing reservation and proxy-stop protections. Replacement installations retain existing accounts, settings, proxy rules, notification connections and automatic-use permissions through the current onboarding flow. Viewing the introduction does not enable features or complete onboarding.

Invalid sign-ins still require the user to sign in again and refresh. The historical disconnect's field root cause remains unconfirmed; these changes do not establish that every disconnect is resolved. The local build, signing checks, replacement installation and interface checks passed. These results do not establish sustained real-provider stability or recovery of an expired sign-in.

## 验证与已知边界 / Validation and boundaries

- **本地构建与自测**：完整 ARM64 优化构建、运行资源核验和 35 组原生自测通过。Carbon 系统热键集成子检查明确跳过，不能视为全局快捷键已验收。
- **安装包一致性**：DMG 挂载、ZIP 解压、构建输出与安装版的 2,167 项完整文件树一致，版本为 **2.5.2 / 147 / 1017v1**，递归严格签名核验通过。
- **覆盖安装**：本机启动和真实界面已核对，12 个账号配置及既有规则保留。此次安装没有自动启用反代、兑换重置卡或重新登录账号。
- **兼容性与签名**：仅提供 macOS 13+、Apple Silicon ARM64 包，使用本地 ad-hoc 签名，未做 Apple 公证；本轮不提供 Intel 或 Windows 包。
- **尚未验收**：历史断开的现场根因仍未确认；真实提供方长期稳定性、Pro5x 重新登录后恢复、重置卡兑换、手机收件和系统全局快捷键仍需相应实机证据。新诊断和建连前重试不等于已根治全部断开。

The optimized ARM64 build, resource verification and 35 native self-test groups passed; the Carbon system-hotkey integration sub-check was skipped. The 2,167-entry application trees match across the build, mounted DMG, extracted ZIP and installed app, with strict recursive signature checks. The local replacement installation retained 12 account configurations and existing rules, and startup and interface checks passed. It did not enable the proxy, redeem reset cards or sign accounts in again. Packages support macOS 13+ on Apple Silicon only, use ad-hoc signing and are not Apple-notarized. Sustained real-provider stability, Pro5x recovery after signing in again, card redemption, phone delivery and global hotkeys remain unverified in this round.

## 下载与升级 / Downloads and upgrade

[DMG（Apple Silicon）](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.2/AiGoodBro-2.5.2-mac-arm64.dmg) · [ZIP 备用包](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.2/AiGoodBro-2.5.2-mac-arm64.zip)

以上为本版发布资产地址，公开状态以 [v2.5.2 Release](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/v2.5.2) 为准。2.5.0／2.5.1 客户端在发布后可通过独立版本号发现更新；旧版 Release 与安装包保留。升级前结束任务、停止反代并正常退出，备份旧 App 和本机数据；覆盖后核对 **2.5.2 / 147 / 1017v1**，按现有新老用户引导检查连接和新设置。已有配置保留；微信、飞书仍可能需要系统权限确认或重新连接。

These are the asset URLs for this version; public availability is determined by the Release page. The separate version allows 2.5.0 / 2.5.1 clients to discover the update after publication. Previous Releases and installers remain available. Finish work, stop the proxy, quit normally and back up the old app and local data before replacing it. Confirm **2.5.2 / 147 / 1017v1** after installation, then follow the existing onboarding flow to review connections and new settings. Existing configuration is retained; WeChat or Feishu may still require system permission confirmation or reconnection.

| 安装包 / Asset | 字节数 / Bytes | SHA256 |
|---|---:|---|
| `AiGoodBro-2.5.2-mac-arm64.dmg` | 217,698,613 | `123757c3dcd89c73e0c84c4c33d7da624a26e29ff909960167d1b05643e36316` |
| `AiGoodBro-2.5.2-mac-arm64.zip` | 181,243,282 | `5e0b93d8a05b6900db370da02dca8ecddecd1c53cad70ece031ce2f3dd32af6e` |

公开资产使用上表标准文件名，内容与本地带 `147-1017v1` 的验收安装包逐字节一致。 / The standard asset names above contain the same bytes as the locally verified packages named with `147-1017v1`.
