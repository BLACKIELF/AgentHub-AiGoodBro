# AiGoodBro 2.5.0（143）

1011v2 · 2026-10-11 · macOS 13+ / Apple Silicon ARM64

本版集中修复反代与微信，沿用 2.4 的 Token Monitor 0.68.0、TokScale 4.18.0、CLIProxyAPI 8.0.20，以及现有主题、侧栏、账号管理、Claude、重置卡与通知设置。

## 本次修复

- **反代控制通道**：阻塞的连接读取与辅助进程输出读取移出 Swift 协作线程池；断线回包抑制 SIGPIPE，保留租约回滚与未知结果的安全停止。
- **额度恢复与调度**：有明确来源的账号额度冷却，仅在核验更新的官方订阅额度后解除。刷新或修改规则不会提前把仍受限制的账号显示为可用；参与、优先、最后使用、点数许可和底线继续作用于真实准入。
- **旧版冷却恢复入口**：停止反代后，可逐账号核验最新额度、备份并确认清理来源不明的旧记录。其他账号与已知限制保留，身份、任务占用、文件完整性或新鲜额度检查失败时不清理。
- **最后使用与忙碌等待**：普通账号暂时占用时先等待，不立即转用末位 Pro20x。额度不足或未参与的账号继续跳过，身份与有效冷却检查保持；已回滚且无其他普通账号可准入的请求明确结束并提示重试，防止重复准入。
- **自定义上限保存**：修复反代规则保存后，编辑框回到 100% 的问题；保存后的编辑值、摘要与持久规则保持一致。保存失败保留草稿，沿用原有额度与点数规则。
- **微信通知**：同一绑定的会话上下文更新不再取消正在发送的通知。停用、换绑、过期、结果不明和去重保护继续保留。
- **更新介绍与演示**：软件内说明与 README 同步更新；加入用户指定的 48 秒 v4 宣传片。演示视频存放于 Release，避免视频进入源码历史。

## 下载与覆盖安装

[下载 DMG](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.0/AiGoodBro-2.5.0-mac-arm64.dmg) · [ZIP 备用包](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.0/AiGoodBro-2.5.0-mac-arm64.zip) · [48 秒演示视频（MP4）](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.0/AiGoodBro-demo-1011v4.mp4)

等待正在执行的任务结束，停止反代并正常退出 AiGoodBro，然后将应用替换到“应用程序”。重新打开后核对 **2.5.0 / 143 / 1011v2**，按引导检查微信、飞书和新设置。安装包不会自动删除账号数据或旧冷却。

2.3／2.4 可发现 2.5 更新。9.6.x 用户需手动下载覆盖；已安装本地 2.5.0（142）的用户也需手动覆盖 143，因为产品版本号相同。

有额度却受旧记录阻挡的账号：停止反代 → 对应账号“清理旧版冷却…” → 核验最新额度 → 确认“备份并清理” → 手动重新开启反代。只有符合条件的旧记录才显示入口；新收到的限制仍按正常规则生效。

## 验证与已知边界

143 已通过 35 组原生自测、592 项 Swift 反代宿主检查、自定义上限的真实 SwiftUI 编辑器回归，以及 77 项原生宿主 → Go 引擎 → 本地 HTTP 链路检查。恢复旧输入行为、旧参与状态或撤销处理的反证均能检出对应故障。Go 完整 race 回归通过；其后的最终等待边界和测试超时修正通过聚焦 race 回归，完整最终源码回归由 [GitHub CI](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/workflows/ci.yml) 再核验。DMG 与 ZIP 分别通过压缩校验、2,144 项完整文件树与递归签名核验。Carbon 快捷键集成在自测环境中跳过。测试使用隔离账号与本地合成上游；143 尚未覆盖安装，真实提供方持续运行、微信手机收件仍需用户现场验收。

应用使用 ad-hoc 完整性签名，未做 Apple 公证。Codex 专用页窄窗口列表的控件挤压仍为已知限制，可先使用卡片模式或加宽窗口。原有来源与许可证见[第三方声明](../Resources/THIRD_PARTY_NOTICES.txt)、[2.4 来源记录](release-notes-v2.4.0.md)；本次没有上游依赖升级。

## 安装包与 SHA256

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| `AiGoodBro-2.5.0-mac-arm64.dmg` | 212,984,092 | `cda38ead0c060ef86866379458675e7501fb134120d60c904220cb8abfb09238` |
| `AiGoodBro-2.5.0-mac-arm64.zip` | 179,798,285 | `124e720235c7a7ac2d93aed14d976da72396ee8f12275e9e2fc8cbb72fef0ae3` |

随包提供同名 `.sha256` 文件；宣传片为用户指定原片，SHA256：`9af3abebd933dbab30f95419768717d862f2564373fde70df1cb2e17da761717`。

## English

AiGoodBro 2.5.0 (143), release 1011v2, fixes blocked proxy control reads, disconnected replies, verified quota cooldown recovery, custom 5-hour rule saving, busy ordinary accounts falling through to Use last accounts, and WeChat context refresh cancelling notifications in flight. Existing customization and pinned dependencies are preserved.

Unknown legacy cooldowns require the proxy to be stopped, a fresh identity-bound subscription quota check and explicit confirmation. The original file is backed up before eligible records for that account are removed. Other accounts and known restrictions remain protected. Start the proxy manually afterward.

Finish active work, stop the proxy and quit normally before replacing the app. Local 2.5.0 (142) users must download build 143 manually because both builds share the same product version. The package is Apple Silicon-only, ad-hoc signed and not Apple-notarized. Isolated regressions do not establish sustained real-provider routing or phone delivery.
