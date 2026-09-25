# CLI 额度与多账号修复 · 0923v9

相较 0923v8：恢复被额度窗口条件挡住的 Grok 余额与周期时间，修复 OpenCode 打包桥接响应误判，增加 Antigravity 和非 Codex 多账号入口。首页用量统计作为独立模块，放在推荐／重置公告之后、账号区之前，默认折叠；展开保留原热力图、趋势和工具明细，不嵌入公告模块，不删除原图表。

## 修复范围

| 平台／功能 | 本轮行为 | 证据边界 |
| --- | --- | --- |
| Grok | 分别显示已返回的购入余额、周期时间、使用百分比；任何一项缺失不丢弃其他项。官方分账字段按美分转换，明确的零与缺失分开 | 已用真实只读 billing 返回及安装后界面核对；当前接口未给使用百分比时仍显示未知 |
| OpenCode | 兼容打包桥接未附带可选 operation 字段的合法响应；继续验证请求、来源、引擎和账号归属 | 实际打包 Node → Swift → UI 映射已用合成账号贯通；只有 Zen 登录不等于拥有 Go 额度，不把 Go 查询失败写成所有服务商登出 |
| Kimi | 支持 ratio-pool 新格式；混合返回时新池覆盖同类旧池，旧格式补齐缺少的 5 小时／7 天窗口 | 合成新旧混合、重复窗口、空数据及边界测试；未重新登录真实账号 |
| Claude | 默认配置失效时可读取同一默认身份的新鲜钥匙串；独立关联账号不读取全局钥匙串；部分窗口缺失不丢弃其余有效窗口 | 非交互式读取与隔离 fixture；不主动刷新 OAuth |
| Antigravity | 加入可添加导航；读取已运行官方桌面的当前账号与模型额度；可关联独立旧 IDE 配置缓存 | 本机安装及签名已核实；官方应用未运行，真实在线额度尚未验证。历史缓存明确标注，不升级为实时额度 |
| 多账号 | Grok、OpenCode、Kimi、WorkBuddy 可创建独立配置后进入官方登录；其余平台统一提供已有配置关联入口。保留编号、重命名与移除关联 | 创建、路径隔离、失败回滚、国内外 WorkBuddy 版本均有合成测试；本轮没有创建或登录真实新账号 |
| 用量统计 | 独立、默认折叠的模块；标题不再随内容消失，位于公告模块下方，展开保留原图表 | 新设置默认折叠，既有显式偏好继续保存；本机按用户要求收起。数据按原统计引擎读取 |

MiMo、TRAE、部分桌面订阅及不支持个人额度的认证方式仍可能缺少可验证接口。保留清楚的未知状态与原因；不以本地 Token 消耗推算套餐余额，不读取浏览器 Cookie 补额度。

## 对抗审查与修复

Jev 提供映射、Grok 独立字段和多账号隔离的文本方案判断。可调度账号以 5.6 Sol／High 完成独立只读审查；主流程逐项修复并验证，而非把建议票当验收：

1. Antigravity 发现活动端点后读取失败，或进程发现本身失败，不再退回可能属于其他账号的缓存。
2. 无法确认所属账号的缓存不显示额度；有身份的历史缓存保持不可用／历史标记，文件修改时间不冒充额度观测时间。
3. Kimi 混合协议不再丢失旧格式中的有效窗口。
4. 实机发现“更多 Agent”选择后浮层未关闭，修复选择动作的关闭行为。
5. Windows 额度仅有余额时，账号行可以显示已核实余额，但全局周期额度不能被标为可用，也不能清除先前已核实的窗口；解析层新增来源区分和保留旧窗口的回归测试。
6. Windows 百分比窗口拒绝负数、超过 100 与非有限值；坏窗口不能借余额字段通过整份响应校验。

## 验证

- macOS 构建、打包资源和签名验证通过；主修复跑完 32 项原生自检。最后的独立模块位置／默认折叠和导航修正，另跑用量界面、主窗口布局和截图三组自检，均通过。
- 本地 CLI 解析、账号读取、多账号创建、Antigravity、其他 CLI 额度及 Grok 重置卡测试通过。
- OpenCode 用实际打包运行时测试桥接链，合成 Zen-only 配置不发网络请求，确认可选字段缺失不会被误判为身份不符。
- 实机已核对 Grok 余额和周期时间、OpenCode 精确诊断、添加账号空名称禁用与取消保留原账号、Antigravity 入口、原图表加载及折叠再展开。
- Windows Web 构建、31 项单元／契约测试、额度仅余额／重置卡场景和用量模块位置／折叠／持久化交互通过。本机无 Rust/Cargo 与 Windows 原生环境，新增 Rust 测试、Tauri、安装包仍须在 Windows 执行。

本地回执在 `.local-artifacts/cli-quota-0923v1-review/`；Windows 本轮记录在 `.local-artifacts/windows-cli-quota-0923v1/` 与 `.local-artifacts/windows-usage-placement-0923v1/`。这些记录与真实账号截图不作为发布资源。

## 安装与继续工作

正式目标为 `/Applications/AiGoodBro.app`，保留原应用标识与 9.6.9（58）版本号；已安装可执行文件 SHA-256 为 `7a960b53c9ae7e5787bbcf5d0fff7a42a169041babcc0d1aa96939d67f860cf8`，通过严格签名验证。本地安装回执位于 `.local-artifacts/cli-quota-0923v1-review/overwrite-installation-final.json`。原应用备份在 `.local-artifacts/backups/AiGoodBro-before-cli-quota-0923v1.app`。用户的主题、账号目录及排序不因安装重置。

Windows 的本轮余额修复覆盖官方解析、DTO 和前端三层，用量模块也同步；非 Codex 的 Windows 多账号与各平台适配器尚未完整移植，不能写成只剩封装。按 [Windows 一次执行交接](windows-port/WINDOWS_AI_HANDOFF_0922v4.md) 继续实现与原生验证。

## 依据与可复用结论

- [Grok 官方账单扩展](https://github.com/xai-org/grok-build/blob/07e35a3dfeed2f200d319ef6c893b5ea286d9a51/crates/codegen/xai-grok-shell/src/extensions/billing.rs)、[官方余额显示](https://github.com/xai-org/grok-build/blob/07e35a3dfeed2f200d319ef6c893b5ea286d9a51/crates/codegen/xai-grok-pager/src/views/credit_bar.rs)：购入余额、套餐使用、按量支出应分别解释。
- [OpenCode Go 官方额度实现](https://github.com/anomalyco/opencode/blob/dev/packages/console/app/src/routes/zen/go/v1/usage.ts)：供应商登录状态与订阅额度资格是不同事实。
- [Kimi ratio-pool 解析实现](https://github.com/steipete/CodexBar/blob/1c8657a083d542fbefec02f17d48c06b01bf099e/Sources/CodexBarCore/Providers/Kimi/KimiModels.swift)：协议迁移需要覆盖新旧混合数据，而不只是分别测试两种完整响应。
- [Antigravity 接入边界与固定来源](antigravity-0923v1.md)。

回归防线：可选桥接字段必须经过真实打包边界测试；余额和重置日期不能依赖百分比窗口存在；额度失败不得替换成另一个账号的缓存；折叠模块要保留可见标题和重新展开入口。
