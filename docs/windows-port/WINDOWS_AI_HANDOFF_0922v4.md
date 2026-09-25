# Windows 一次执行交接 · 0924v1

0924v1（Windows 侧）：在 PR #12 上完成 Windows 非 Codex 多账号、额度与 Antigravity 原生适配。
新增平台目录与账号隔离模式、非 Codex 额度契约（未知／不支持不被渲染成成功）、Antigravity
Windows 原生发现与只读查询（进程路径／启动时间／端口归属／WinHTTP 环回）以及旧版 IDE 缓存的
严格边界，并把平台维度接进账号目录界面。实现与未验证边界见
[0924v1 Windows 多平台实现](WINDOWS_MULTI_PLATFORM_0924v1.md)。

0923v9 相较 0923v8：官方额度解析、DTO 与前端三层均能保留没有百分比窗口时的有效余额／重置卡，明确区分零与未知；余额仅有值时不会误报全局周期额度可用或抹掉上次已核实的窗口，畸形百分比继续拒绝。首页“用量统计”是推荐／重置公告下方的**独立模块**，在账号区之前，默认折叠；展开保留热力图、趋势和工具用量明细，原 Usage 标签继续存在。Web 构建、31 项单元／契约测试以及新增额度、位置、折叠与偏好持久化交互已通过。本机没有 Rust/Cargo 或 Windows 原生环境，新增 Rust 测试、Tauri 运行和安装包均待 Windows 验收。

Mac 本轮还增加 Antigravity、独立 CLI 多账号入口及 Grok／OpenCode／Kimi／Claude 的额度修复，见 [0923v9 实现与依据](../cli-quota-repair-0923v9.md)。Windows 当前运行模型仍以 Codex 为中心，尚无完整的非 Codex 原生适配；接手后须先完成这部分移植，再做原生验收和打包。

相较 0923v1：深色「液态键帽」默认值、7 套既有主题、毛玻璃首页、紧凑推荐与公告、账号卡片／列表切换及统一编号已写入 Windows Web 实现；保留模型与调度、详情、引导、截图及 About。有效的用户主题选择继续保留，损坏的主题 ID 回退到原有安全主题。Web 构建、31 项单元／契约检查、31 项视觉／交互检查及后续 12 项 Dashboard 补测通过；本机没有 Rust/Cargo 和 Windows 原生环境，新增 Rust 默认值测试及 Tauri 构建、安装均尚未在 Windows 执行。

这轮增量统一在 [草稿 PR #12](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/12)；旧 PR #3、#10、#11 的提交已并入其历史，重复入口已关闭。接手时从 PR #12 最新提交取得源码，核对下方新增代码及本版本说明确实存在。Mac 原生界面基线与证据边界见 [0923v8 实现记录](../ui-implementation-0923v8.md)。

0923v1 相较 0922v4：移除所有重置日历；账号详情透传所属目录备注，并验证重排和改备注后的对应关系。保留近期记录、来源、倒计时、截图、引导、全部致谢及关于 AiGoodBro（微信复制与二维码）。视觉沿用原版图标、头像、配色、额度条与图表，采用新版信息骨架。除日历外，后续删除功能需先逐项与用户确认。

0922v4 基线：不再只交付账号目录和额度读取。此分支带齐 Mac 9.6.6–9.6.9 源码，并新增 Windows 公开重置预告/近期记录、真实秒级计时、账号详情、独立折叠、引导、About、模型偏好和交互式 CLI 工作流。

## 可直接交给 Windows AI 的任务

接手 AiGoodBro 草稿 PR #12 的最新提交；在它进入 main 前，不要从旧 PR #11 或仅从当前 main 取源码。先读当前根目录及 windows/AGENTS.md 和本文，以实际代码为准，不要回退到旧交接所写的 Mac 9.6.1 / Windows 仅目录阶段。

你负责把 Windows 原生构建、验证、修复、安装包和交付完整跑完。可以修改完成目标所必需的任何 Windows Rust、Tauri、React、PowerShell、测试、CI、资源和文档；不限定文件数量，不必为普通修复反复询问。自行修复所有发现的错误并复测，完成前进行第二轮对抗审查。已有功能要保留；遇到环境缺失先检查已有安装，再用官方来源补齐必要构建依赖。不要把“可以构建”当作“已安装验证”，也不要只返回计划。

最终提交可审查的 PR、MSI 与 NSIS 安装包、SHA-256、对应源码提交号，以及已实测/未实测清单。测试使用临时目录与合成账号；涉及用户的真实登录或账号切换，由用户完成交互验证，不需要为其他普通代码工作停下来。

## 当前实现与接线位置

| 功能 | Windows 代码 | 原生验收重点 |
| --- | --- | --- |
| 账号目录、备注、顺序、查看、移除 | `commands/profiles.rs`、`ProfilesPanel.tsx` | 中文/空格路径、重复目录、关联变化、保存失败 |
| 官方套餐与额度 | `readers/codex_app_server.rs`、`commands/profile_quota.rs`、`ProfileQuota.tsx`、`AccountDetails.tsx` | 新鲜 rateLimits 套餐优先；Pro 5x / Pro 20x；美元、原始点数分别显示，未知为 —；缺少窗口不是 0 |
| 0923v9 额度仅返回余额／重置卡 | 同一官方解析、DTO、前端三层；另查 `readers/codex_dashboard.rs` | 窗口百分比未知时仍显示已核实金额／卡数；不能把仅余额误报为周期额度可用或清除上次已核实的窗口；显式空窗口和畸形窗口分别判定 |
| 倒计时 | `utils/resetTime.ts`、`ResetCountdown.tsx`、`QuotaOverview.tsx` | 按绝对时间每秒计算；睡眠恢复/漏帧追上；到点等待额度或来源确认；不每秒请求网络 |
| 公开预告、历史、维护者消息 | `commands/public_feed.rs/.ps1`、`publicFeeds.ts`、`PublicResetPanel.tsx` | PS 5.1/7 UTF-8、WebView2；限时/限大小；缓存过期和坏响应；来源变更不伪报完成 |
| 首页独立折叠、推荐入口 | `HomeSection.tsx`、`DashboardHome.tsx`、`RecommendedSkills.tsx` | 各区块分别记住状态；窄窗口无水平溢出 |
| 0923v9 首页用量统计 | `windows/Dashboard.tsx`、`DashboardHome.tsx`、`UsagePanel.tsx`、`ToolUsageList.tsx` | 紧接公告的独立区块，默认折叠；展开有热力图、趋势、工具明细；重开保留显式偏好；原 Usage 标签仍可用 |
| 0923v8 毛玻璃、默认主题、卡片／列表 | `windows/Dashboard.tsx`、`Header.tsx`、`ProfilesPanel.tsx`、`ProfileQuota.tsx`、`utils/paletteCatalog.ts`、`app_state.rs` | 新用户深色液态键帽；旧有效主题保留；7 主题可选；卡片／列表状态持久化；窄屏重排、未知与零区分；高对比度／减少透明度实色回退 |
| 引导与联系方式 | `CodexAccountGuide.tsx`、`AssistantContact.tsx`、`public/assistant-wechat.jpg` | 添加 Codex 独立账号的清晰引导；微信 AiGoodBro 一键复制；完整二维码；弹窗 Close/Esc 与焦点返回 |
| 模型与调度、真实终端 | `workflow.rs`、`workflow_reader.rs`、`commands/cli_workflow*.rs`、`AccountWorkflow.tsx` | 默认展开；开关保存后读回；关闭不依赖额度；官方模型/强度；独立 CODEX_HOME；只有交互式终端，不自动发任务 |
| 启动/取消/移除/退出 | `main.rs`、`commands/profiles.rs`、`cli_workflow*.rs` | 同一账号重复启动被阻止；移除与启动竞态；只停止自己的进程树；还有终端时普通退出不杀会话 |

表中 `commands/` 在 `windows/apps/codexu-tauri/src-tauri/src/`；前端在同级 `web/src/`；核心在 `windows/crates/codexu-core/src/`。

## 执行顺序与命令

完成依赖预检后，优先使用已写好的统一入口，一条命令跑完可自动化的测试与双格式打包：

```powershell
pwsh -NoProfile -File windows/scripts/Invoke-ReleaseReadiness.ps1 -Version 9.6.9
if ($LASTEXITCODE -ne 0) { throw 'Release readiness failed; repair the reported step and rerun.' }
```

它依次运行原生环境预检、Windows PowerShell 5.1/7 契约、Rust 格式与测试、Web 构建和两轮视觉验证、MSI/NSIS 打包；失败立即停止。每次使用新输出目录，`report.json` 记录 Git 提交号、工作树状态、源码指纹、实际步骤与退出码、安装包 SHA-256。只需检查而不打包时加 `-SkipPackaging`；只查看执行清单时加 `-PlanOnly`。报告中的原生交互及覆盖安装保持 `not_run`，须按下方第 4–8 项实际完成后补齐；脚本不会代替用户登录、切号或关闭现有应用。

下面保留分步命令，供失败定位和必要补测使用，不必在统一入口全部通过后重复运行同一组检查。

1. 检查当前分支、已有修改与依赖版本。保留他人的修改；从包含本交付的最新提交创建 `codex/windows-native-0922v4` 或同类分支。不要在过期的 Windows 移植快照上打包。
2. 检查 Windows 10/11、MSVC/Windows SDK、Rust 1.97.1、Node 22、npm、WebView2 Runtime 和 Tauri 2 CLI。使用仓库现有预检与原生验收入口，不新建重复工具链。终端功能的真实验收还需要官方 Codex CLI 原生 exe。
3. 从仓库根目录执行以下 PowerShell 命令，任一步失败立即修复并重跑该步骤；不要忽略退出码继续打包。

```powershell
$ErrorActionPreference = 'Stop'
function Check-Exit { if ($LASTEXITCODE -ne 0) { throw "Previous command failed: $LASTEXITCODE" } }
Push-Location windows
cargo +1.97.1 fmt --all -- --check; Check-Exit
cargo +1.97.1 test --workspace --locked; Check-Exit
Pop-Location
powershell -NoProfile -File windows/scripts/tests/Test-PublicFeedSyntax.ps1; Check-Exit
powershell -NoProfile -File windows/scripts/tests/Test-ReleaseReadiness.ps1; Check-Exit
powershell -NoProfile -File windows/scripts/tests/Test-NativeWindowSelection.ps1; Check-Exit
powershell -NoProfile -File windows/scripts/tests/Test-NativeVisualCaptureWorkflow.ps1; Check-Exit
pwsh -NoProfile -File windows/scripts/tests/Test-PublicFeedSyntax.ps1; Check-Exit
pwsh -NoProfile -File windows/scripts/tests/Test-ReleaseReadiness.ps1; Check-Exit
pwsh -NoProfile -File windows/scripts/tests/Test-NativeWindowSelection.ps1; Check-Exit
pwsh -NoProfile -File windows/scripts/tests/Test-NativeVisualCaptureWorkflow.ps1; Check-Exit
Push-Location windows/apps/codexu-tauri/web
npm ci --no-audit --no-fund; Check-Exit
npm test; Check-Exit
npm run build; Check-Exit
$env:CODEXU_VISUAL_BROWSER = 'chromium'
npx playwright install chromium; Check-Exit
npm run test:visual -- --update-snapshots; Check-Exit
npm run test:visual; Check-Exit
Pop-Location
```

首次生成基准必须检查截图，不等于视觉回归已通过；随后不更新基准的复跑必须通过。基准、实际图和差异图保留在 `.local-artifacts/visual/`，不要提交真实账号截图。

4. 启动当前构建做原生验收：中文与英文、100%/125%/150% 缩放、窄窗口、键盘 Tab/Shift-Tab/Esc、7 套主题、深浅模式、新设置的深色液态键帽默认值与旧主题保留、卡片／列表切换和重开持久化、减少透明度／高对比度、主页所有折叠、账号详情/引导、About 复制/二维码、公开预告秒数、近期记录全文/来源、确认所有页面无重置日历、网络失败和恢复。
5. 对交互式 CLI 用隔离 fixture 先验证进程与偏好，再让测试者选择已登录的独立 Codex home：只读额度、官方模型列表、选择工作目录、打开终端、从终端正常退出、应用内明确结束、启动过程中关闭参与、拒绝重复启动、运行中尝试移除、运行中尝试退出应用、重新打开应用后偏好仍正确。没有真实成功回执就继续修复；不要伪造终端状态。
6. 对抗审查后再次执行受影响测试。确认工作目录和实际账户绑定一致，未改写全局认证。每个坏值、过期快照和失败保存都应保持明确的失败/旧记录状态，不可显示绿色成功。
7. 使用已有打包脚本，不另起一套打包链：

```powershell
pwsh -NoProfile -File scripts/build-windows-release.ps1 -Version 9.6.9 -OutputDirectory dist/windows
if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
Get-ChildItem dist/windows -File | Get-FileHash -Algorithm SHA256
```

8. 在 Windows 干净用户目录和覆盖安装场景各验证一次 MSI/NSIS：资源齐全、About 二维码、目录/设置不丢失、托盘退出、卸载不会删除用户的 Codex 账号目录；恢复启动只读取元数据，不自动发送模型请求。
9. 提交聚焦改动、推送 PR，描述实际行为、失败处理、源码提交号、测试结果和安装验证。交付安装包与校验值。不要仅凭 macOS 上的浏览器测试标注 Windows 已验收。

## 对齐还需在 Windows 继续完成的部分

这里没有把未实现的能力藏成无效按钮。以下是完整产品迁移工作，允许直接实现并验证，不需要额外限制到“只能封装”：

- Windows 内托管的新增/重新登录流程目前是清晰指引与已有目录关联；可按 Mac `AccountLoginProtocol`、`DeviceAuth*` 和 `NextSetupGuideView` 对齐取消、超时、回调归属与写后身份核验，接原生凭据保护。
- 自动后台派单、跨应用任务恢复与 Desktop 身份切换尚不是 Windows 此次交互式终端切片。按 Mac `DispatchParticipationSync`、`CodexProfileStore` 和 `scripts/next_dispatch_*` 的行为设计 Windows 实现，不能直接运行依赖 macOS 的终端脚本；已有 profile ID、模型偏好、进程持有、原子保存与额度解析可复用。
- 其他 CLI 的真实余额/消耗/剩余/重置适配需要用 Windows 安装与官方返回验证。参考 Mac `LocalCLIAccountStore`、`LocalCLIQuotaWindowDetails` 及对应 `tests/test_*cli_quota.py`；已有记录量与官方剩余额度应分别标注，不以 token 消耗推算套餐余量。CLI 不提供某项时明示未知。
- 0923v9 已写好 Mac 的独立 Grok、OpenCode、Kimi、WorkBuddy 配置创建及其他平台的已有配置关联入口。Windows 已在 0924v1 完成平台目录、隔离模式、额度契约与 Antigravity 只读适配（见 [0924v1 实现](WINDOWS_MULTI_PLATFORM_0924v1.md)）；仍缺非 Codex 平台的交互式终端启动、Antigravity 的 Authenticode 签名校验，以及真实安装的在线额度实测。
- 维护者消息已经可以读取；Windows 原生新消息通知、系统授权、首次基线与去重还需接线并做 Windows 通知验证。参考 Mac `PublisherMessages`，避免初次启动把历史消息全部推送。

这些事项是诚实的剩余能力清单，不是禁止实现。继续工作时以用户的完整产品目标为准，可以完成它们后再统一打包。真实用户凭据、未完成工作、付费回退和不可逆操作仍按实际授权处理。

## 交付报告要求

记录准确的 Git HEAD、Windows/PowerShell/WebView2/Codex 版本、构建/测试退出码、已验证功能、安装路径与版本、MSI/NSIS 校验值。写清新增内容相对 0922v4 的差异。不要把“已写代码”“模拟测试通过”“原生运行成功”“安装验证成功”混为一项。

## 官方调用入口核对

交互终端与只读探测使用同一份官方订阅配置：选择内置 `model_provider="openai"`，通过标量 `openai_base_url` 固定模型服务为 `https://chatgpt.com/backend-api/codex`，通过 `chatgpt_base_url` 固定账号服务根为 `https://chatgpt.com/backend-api/`。不要重定义 `model_providers.openai`：实际 CLI 0.154.0 会拒绝覆盖这个保留的内置名称。探测在启动终端的同一工作目录中，先用 `config/read` 检查生效配置，再读取账号和额度；未匹配则不继续。不要把订阅令牌发到 API-key 模型入口。核对依据：[OpenAI provider 实现](https://github.com/openai/codex/blob/main/codex-rs/model-provider-info/src/lib.rs)、[默认账号服务配置](https://github.com/openai/codex/blob/main/codex-rs/core/src/config/mod.rs)。后续 CLI 升级以安装版本能力和官方来源复核，不凭模型名称推断兼容。
