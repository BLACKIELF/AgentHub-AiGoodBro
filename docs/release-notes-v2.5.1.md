# AiGoodBro 2.5.1（146）

1015v3 · 2026-10-15 · macOS 13+ / Apple Silicon ARM64

本版包含 145 已有改动与首次安装通用偏好，完整本地构建及 35 组原生自测已通过。DMG／ZIP 的版本、签名及完整内容一致性已核对；146 未覆盖安装。远端检查见 [GitHub Actions](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions)。[2.5.0（143）](release-notes-v2.5.0.md) 的原有 Release、安装包、宣传片和展示资料保留。

## 相较公开 2.5.0（143）

- **反代并发与等待**：区分共享状态文件的锁竞争与真实账号占用；仅确定未写入、未预留的竞争允许安全重试。排队遵守原等待期限及取消信号，已预留后的短暂文件锁竞争在原期限内重试；未知结果继续安全拒绝。等待超时或安全重试耗尽提供 `Retry-After: 1`。已接入响应不重放，普通账号优先、Pro20x 默认最后使用、参与撤销和点数底线保留。
- **反代状态与规则**：临时错误结束后按最新额度证据显示，忙碌标签明确为上次请求报告；关闭面板取消待核验的旧冷却清理。Plus 账号可统一设置 5 小时已用上限并单独调整；低于 100% 时达到上限停止新请求，已有响应继续完成，100% 沿用原有点数接续规则。Codex 列表的相关开关分组换行。
- **反代引擎 8.0.28**：改善多行 SSE 解析与 HTTP/2 连接关闭分类，保留取消期间真实额度冷却记录；既有身份、额度、租约和禁止自动重放检查继续生效。
- **用量统计**：保留 Token Monitor 0.68.0 的界面、侧栏、浮窗及统一 TPM，选择性回移 0.70 的压缩／归档 Codex 日志读取、计价、推理 Token 与历史读取修复；TokScale 保留 4.18.0 基线并采用固定扫描器修订。继续采纳 0.71 的两项修复：归档统计交接后台后释放重复占用，读取失败保留上一份完整统计；可选菜单栏浮窗点击关闭后不立即重开。没有完整升级至 0.71，不增加提供方或启用原本关闭的 Dots 观察链路。
- **Claude 配置保护**：对齐 Claude-swap 0.27.1 的路径规则，空旧配置不遮住当前配置；保存和切换固定配置路径并复核身份，失败时只恢复本次持有的写入，保留并发产生的外部数据。
- **重置卡变化与到期提醒**：记录同一已核实账号可用次数的增加与减少，显示前后数量及观察时段；未知减少原因明确标注。已知到期时间进入 24 小时内，沿用已开启通道提醒并按卡、到期时间及通道去重。首次同步不补发历史变化，提醒不兑换卡片；发送结果不确定时暂停自动重发。临期自动使用继续默认关闭、逐账号授权、默认提前 30 分钟。已完成提醒按持久观察记录清理，保留最新去重依据；待发送、发送中与结果不确定的记录保留。
- **微信与消息**：启动时调整通知内容不再中断已保存连接读取；保留同一会话上下文更新不取消在途通知的修复。飞书在发送前被取消的请求可在恢复后重试；已提交且结果不确定的请求保持禁止自动重发。消息使用统一短时间和独立品牌尾标；微信完整任务回复按字节安全分段。倒计时保持分钟级更新，并在到期时额外更新一次文案。停用、换绑、迟到回执、去重和不确定结果保护保留。
- **引导、精选与关于**：新功能说明与安装引导同步；REA、JEV 保留为按需安装入口，可识别的新装或覆盖后只读检查已安装项目，支持逐项隐藏和手动重查。检测不代表已连接或自动安装。关于页增加“超值低价GPT订阅点击有惊喜”入口，点击打开 aigoodbro.com，版本标题读取实际安装信息，官网、GitHub 和小程序预告保留。
- **首次安装偏好**：跟随系统主题、账号卡片、自动隐藏侧栏、菜单栏剩余额度与倒计时、K 线全部历史统计、玻璃透明度 74%／深度 84%、主窗口 ⌘U、侧栏 ⌘I。新用户仍进入完整引导，老用户保留全部配置。只包含通用界面默认值，不携带账号、凭据、私人路径、端点或授权。详见[首次安装偏好](first-install-preferences.md)。

全部既有账号、主题、邀请、反代、重置卡、消息、侧栏及浮窗能力保留。推荐工具入口不表示这些工具已打包或完成连接；本机 JEV 工具升级不算本应用的依赖升级。

## 下载与升级

[下载 DMG](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.1/AiGoodBro-2.5.1-mac-arm64.dmg) · [ZIP 备用包](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.1/AiGoodBro-2.5.1-mac-arm64.zip)

发布入口见 [v2.5.1 Release](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/v2.5.1)。2.5.1 使用独立版本号、标签和安装包，发布后 2.5.0 客户端可通过版本比较发现它；原有 `v2.5.0` 保留。9.6.x 客户端仍需手动下载覆盖。

等待自己的任务结束，停止反代并正常退出 AiGoodBro，备份旧 App 和本机数据后再覆盖。正式包重新打开应核对 **2.5.1 / 146 / 1015v3**，并按引导检查微信、飞书和新设置。已有配置保留；微信、飞书可能需要 macOS 钥匙串授权。通知发送与自动使用仍需用户选择，授予钥匙串访问不会自动发测试消息或使用卡片。

目标安装包采用 ad-hoc 完整性签名，未做 Apple 公证；本次仅面向 macOS 13+ Apple Silicon ARM64。

## 验证状态与边界

146 的本地发布构建流程成功结束，用时 850.791 秒，2,358 项构建输入无漂移；已安装主程序保持不变。35 组原生自测通过，其中首次安装偏好与老用户配置保留通过 117 条隔离断言。Carbon 系统热键集成明确跳过，未注册系统热键；需要 root 的非属主 LaunchAgent 夹具也按权限条件跳过。DMG／ZIP 的 2,167 个条目（1,583 个文件）与构建 App 一致，版本与严格签名核验通过，校验值见下表。另通过 436 项宿主隔离检查与 11 项锁竞争检查；消息账本 158 条断言和独立 18 条对抗断言、回调 19 项行为及 7 项连接检查、倒计时 16 项断言均通过。远端检查记录见 GitHub Actions。

**146 未覆盖安装。**用户正在使用反代，本轮保留运行中的 145，覆盖安装和真实界面验收暂缓。发布脚本为每次构建生成独立测试记录名称，并提前拒绝冲突和非法目标，保留旧记录及真实失败阻断。

真实提供方持续反代、真实登录、重置卡兑换、微信／飞书手机收件及全局快捷键，需要各自的实机回执。隔离测试、本机构建、连接配置可读或 API 接收均不自动证明这些结果。尚未定位的历史反代中断不作永久稳定保证。

来源与许可证继续保留，见[第三方声明](../Resources/THIRD_PARTY_NOTICES.txt)、[反代声明](../Companion/LocalProxy/THIRD-PARTY-NOTICES.txt)及 [2.5.0 发布记录](release-notes-v2.5.0.md)。宣传图片及双语视频沿用 [1012v1 展示资料](showcase/1012v1/README.md)，历史截图不作为 146 的安装验收。

## 安装包与 SHA256

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| `AiGoodBro-2.5.1-mac-arm64.dmg` | 211,244,366 | `7be0e1fb4e8d75d7a77f7f79c3fb42b3b545a6cf162edfbd73074c12c9eed5b2` |
| `AiGoodBro-2.5.1-mac-arm64.zip` | 181,241,734 | `705d908cf30d3e0c732757b196cc92781f0e04b65896067fd401b68eb79d13fb` |

每个包提供同名 `.sha256`；汇总校验文件见 [SHA256SUMS](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.1/SHA256SUMS)。

## English

**2.5.1 (146), release 1015v3**, combines build 145 changes with general first-install preferences. The full local build and 35 native self-test groups passed. DMG and ZIP versions, strict signatures and complete contents have been verified; remote checks are available in GitHub Actions. Build 146 has not been installed, and the 2.5.0 assets and showcase material are retained.

This release improves proxy lock contention, admission deadlines, cancellation and retry guidance; pins CLIProxyAPI 8.0.28; protects Claude configuration handling; adds verified reset-card change and expiry alerts; and fixes WeChat connection loading and reply segmentation. It retains the Token Monitor 0.68.0 interface with selected 0.70 / 0.71 fixes, rather than adopting the full 0.71 release. REA and JEV are optional recommendation entries, not automatically installed or connected tools. The subscription offer opens aigoodbro.com. Pre-send Feishu cancellations remain retryable; uncertain sends stay protected. Completed notice records are compacted using durable deduplication evidence, while pending, in-flight and uncertain records remain. Countdown labels keep minute updates with one additional update at the deadline.

First-install defaults are system appearance, account cards, an auto-hiding sidebar, menu-bar remaining quota and countdowns, all-time candlestick trends, glass transparency 74% / depth 84%, ⌘U and ⌘I. Onboarding remains required. Returning users retain all configuration; no accounts, credentials, private paths, endpoints or permissions are included. Notification sending and automatic reset-card use remain subject to user choice and authorization.

The separate 2.5.1 version allows 2.5.0 clients to discover it after publication without replacing the old release. Stop work and the proxy, quit normally and back up before replacement. WeChat and Feishu may require Keychain permission again. The target is macOS 13+ on Apple Silicon ARM64, ad-hoc signed and not Apple-notarized.

The local release build completed successfully in 850.791 seconds with no drift among 2,358 inputs, leaving the installed executable unchanged. The 35 native self-test groups passed, including 117 isolated first-install and returning-user assertions. Carbon system-hotkey integration and the root-only unowned LaunchAgent fixture were skipped. All 2,167 bundle entries (1,583 files) match the built app in both packages; byte sizes and checksums are recorded above. Build 146 has not been installed; installation and GUI acceptance are deferred while build 145 and its proxy remain in use. Sustained provider routing, real sign-in, card redemption, phone delivery and global hotkeys each require separate device evidence.
