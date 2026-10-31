# Windows 接手与封装交接 — 1031v1

本次按用户要求停止扩展实现和新测试，保存现有代码交 Windows 接手。**这是 WIP 源码交接，不是发布验收通过。** 预计先读本页 8 分钟；精确文件与 SHA256 见同目录 `WINDOWS_HANDOFF_SOURCE_1031v1.json`。该清单只覆盖本次第二批 101 个代码、测试、资源与构建入口文件，不包含本页和清单自身。

## 从哪里继续

- 仓库：<https://github.com/BLACKIELF/AgentHub-AiGoodBro>
- 现有草稿 PR：<https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/40>
- 工作分支：`codex/windows-parity-local-1029v2`；PR 基线：`codex/windows-parity-1029v1`。本页所在提交是交接快照，后续提交继续用本分支或从该精确提交建立有明确对应 PR 的 `codex/` 分支。先保留本机改动，勿强制 checkout/reset。
- 第一批诊断源码基线：`2d8ab044aa2a0b8610b2c2a68f011212fc1558ed`，tree `f160cc030beeea9095d657c8bfc23fad9a24cb62`。实际 PR merge `4ad54b628a1f4a626486ab77124d088164b5e359` 的完整 tree 相同。
- 本次交接在该基线之上加入原先隔离的第二批 WIP，**不能引用 2d8 或 859 的旧产物证明这些新文件已通过**。
- 对齐合同是已提交的 Mac165 `ad74ecd040d498f590c889081ce7c2c8fc13f00b`；沿 [既有 Windows 路线图](WINDOWS_PARITY_ROADMAP_0919v1.md) 和 `windows/AGENTS.md`，不从 Mac 未提交工作树复制代码。
- 本页未完成项由 Windows 接手者负责完成、原生验证、封装 MSI + EXE、提交并推送源码、更新 PR、上传安装包与 SHA256/验收回执，再回报链接。不要直接发布 stable/latest，也不要将 WIP 包当已验交付。

## 第一批真实验收状态

| 精确源码 | 已有证据 | 尚不能声称的结果 |
| --- | --- | --- |
| `859056964aece61b682a302f9abc21c441058644` | [包与双升级 run 41183156149](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/runs/41183156149) 成功且独立离线验包通过；Windows Rust、两次原生冷启也独立通过 | [CI 41183156022](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/runs/41183156022) 网页首轮 254/254、复验 253/254，导航报 ERR_NO_BUFFER_SPACE；所以不是整体验收通过 |
| `2d8ab044` | [CI 41186445163](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/runs/41186445163)：网页 254/254 两轮、Windows Rust 与 native-visual job 均 success | Mac job 124494225969 在 cleanup-retry 合成测试 SIGTRAP，CI required failure；同一 binary 自动 LLDB 诊断重跑 28/28 exit0 不能消除原失败，历史根因未证 |
| `2d8ab044` 包 | [package 41186445162](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/runs/41186445162)，job 124494225867，交接快照仍在 Validate and package Windows x86_64 | 未记录最终包/升级/独立验收，不能将运行中写为通过；接手先读原 run，不重复 dispatch |

本次停止前没有对 2d8 失败重跑或修补，也没有重跑已通过网页。新增诊断保留所有合成用例失败 context、受限 trace 和本任务进程聚合；断言、超时、像素阈值不变。859 旧资源错误在 2d8 未重现，不等于根因修复。

859 的现有产物可从上述 package run 的 artifacts 获取（不是本次 WIP 包）：installers artifact `13036852607`、readiness `13036463987`、MSI upgrade `13036848062`、NSIS upgrade `13036593979`。实际安装器哈希：

- MSI：`c82c3b920c155c2b784242c519b4cb0193cbd7bfa923184f3f33b34f0a3c9497`
- EXE：`5a1b2e74f51f6a8854154d75d41ce729f696fb0c79b5a6fc066d047b665ebdea`
- 两包共同实际 AMD64 App：`c1e79a1e55d683eb80a6178b4337434af4666b54517603deaecffcf6f48a3093`

已接受的独立 [win1031v1 draft](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/untagged-5b31e62e90da54e887c4) 仍是更早的 `86263b0c` 交付。不要覆盖它或把它描述成包含第二批。

## 第二批已写与未完事项

以下“通过”均限指定 host/合成或源码审范围。整个交接快照尚未做同源完整构建和 Windows 原生验收。不得只因某模块文件已存在就显示 Ready。

| 项目 / 原作者 | 已写、已验证 | Windows 接手必须完成 |
| --- | --- | --- |
| Python 检查/选择；new_account + integrator | `runtime_setup/python*.rs`、`commands/python_runtime.rs`、`PythonRuntimeSetupPanel.tsx`。11 core、parser2、React6、类型检查；错误后清旧 Ready，选择回执丢失只允许检查，不假称保存未变。持同选择锁与 held image，显式坏选择不 fallback | 用实际 Windows Python 验证 >=3.9、ssl/sqlite/ctypes/msvcrt/Asia-Shanghai；只用隔离 home、固定只读脚本，不自动装 Python/tzdata。补真实 probe/cleanup 原生门禁 |
| Companion 安装事务；new_account | `companion_setup/`、`windows/companion/`。真实16载荷 prepare → SetupStore 安装 → launcher.main 合同（仅 transport mock）；6 Python/19 setup。备份、CAS、故障回退只碰本轮写入字节；旧两个配置保留、不新造第二 authority | 核真实 Windows 文件 owner/reparse/持久化/恢复。现资源16载荷+manifest+receipt共18包文件；不是 Mac18槽数量对齐。不可把未消费的 dispatch-codes/policy 文件生成成假功能 |
| Companion 协议与实际 App 组合；new_account + integrator | `companion_bridge/`、`commands/companion_bridge_{backend,runtime}*.rs`、`task_hub.rs`。core14、backend9、runtime16 host；create/approve 各阶段先 durable Pending，Unknown 只 lookup、不重 POST；guard 转入 Session 后须 action/账号/项目精确终态才释放 | `native_tests.rs::cases()` 仍需接成真实非 ignored Windows driver，复用受限 token/owned Job；真实 Python one-shot → Receiver → AppBackend → Hub loopback 尚未执行。先核 cfg(windows) 编译、真实 IPC 断线/取消/重启/Job 空与失败句柄保留，再称可用 |
| Companion 安装入口/资源；integrator | `commands/companion_setup.rs`、State/main、Guide、`build.rs`/资源映射/readiness/build caller 已接；三固定 IPC inspect/prepare/confirm，不接受任意目标或 approved。host non-test check、8 exact pin cases、真实 Guide 1+1 与叶8+8 React通过，独审通过 | 完整 Windows non-test/release 编译、安装包内18文件及实际安装后哈希/路径验证；真实 prepare不启动、confirm才 bind/start、无变化但 Receiver 未启仍不能假 Ready |
| 正常退出/取消恢复；integrator + new_account | `quit.rs`、main、runtime suspended Candidate；正常退出不先 seal Hub，late guard/取消恢复同来源、同 journal、不重放；force 才 seal。quit6、runtime16 host及源码独审 | 实际 Windows 取消退出、late adopted guard、stop unknown、恢复失败准确不可用；不能丢 ownership/重复 bind，不能将关闭 Job handle 冒充已同步确认进程树为空 |
| 原窗口接续；windows_release + integrator | `desktop_owner/` client+journal 与 `commands/desktop_owner_actions*.rs`。core9、journal9、caller13、native context2，独立审；原生 synthetic case 已写但未执行。discard_preview 只释放未提交预览，Unknown 保持 operation ID | **父 State/IPC/UI 仍未接**；同窗口 fresh owner+完整 snapshot 同 thread/local、动作前 native source/metadata 重核；迟到预览在 UI 关闭后也须 discard。中断应从真实当前 snapshot 推导 expected turn，不猜 UI 库存。Unknown 只能状态查询，不能换 UUID/自动重发/改用 CLI |
| 原 owner 官方 Windows peer | 已静态核官方26.1027.3384.0 pipe/协议；仅保留ASAR，无完整固定 MSIX/hash | 先取得固定官方整包来源/hash及空间证据，不能把 latest 当历史固定版。隔离 runner 可尝试官方签名/ACL同SID/session非提升 connect→initialize→close；管理员部署与非提升运行分开，Server2025支持仍未证。不发现真实聊天、不 start/interrupt、不放宽门禁。此 smoke 也不证明聊天/账号完整功能 |
| 网页池客户端 L04；integrator | `provider_pool/client*.rs`、`local_cli/launch/provider_pool.rs`、`commands/cli_workflow/provider_clients.rs`、`ProviderPoolClients.tsx` 已写；核心计划5 host/独审 | 当前完整 native启动/退出/Job/UI组合待冻结、专属实际渲染与 Windows 测试。confirm_model→spawn须同 with_connection gate，ClientPlan/home锁留到整个 Job 为空；key仅 native env，不上Web/argv；不动现有真实 profile |
| Agy；windows_release 调查 | Mac真实consumer只要求兼容本机agy、`--gemini_dir`、独立私有settings和env key；没有额外“必须独立发行形式”前提。Windows source 尚未写 adapter | 当前 Native+Antigravity 明确拒绝。依据官方/已核实际Windows CLI入口实现 typed adapter，处理 PE/.cmd、固定参数、可信路径与 owned process；不能凭名称或打开 Desktop GUI 冒充 CLI，不新造 runner。调查发现候选Windows CLI不等于已验兼容 |
| A–Z / 单次 model-effort-tier / savedFast / plan exclusions / notAfter；new_account + integrator | `workflow_execution*.rs` 纯规则16 host与savedtier实际schema单case通过；`workflow.rs`字段/validate已加。稳定字母按最高占用+1，删profile墓碑不复用；savedFast继承、显式default只覆盖本次；deadline与plan规则拒绝失效，不静默降级 | **仅规则与schema，不是完整功能**。需现有workflow原子持久setter/显式登记分码/实际UI消费者；native model/list证据需受控完整cleanup，不能用静态白名单。A–Z应解析实际独立profile/home/session，不能只改当前单Session alias。Bridge selector/Scope/lease/create bodyHash、Go最终重新派生、savedtier消费者与字段兼容均未接 |
| M06/N02与其余35合同 | 第一批已有local inventory、手动文字、账号/统计/导航/推荐能力；真实账号/消息从未操作 | 原owner actions不等于自动续做、微信聊天关联/自动回复已完成。M05刷新选项、P04catalog participation映射、U03长截图等此前窄差异仍应按既有35项合同逐项核，不以本表或旧矩阵的 stale pending 自动宣布完成 |

原 owner 的 ActiveSystemScope/guard 仅证明本 App 当前来源与并发保护，**不证明官方 GUI 使用哪个管理账号**。Mac可执行合同仅 thread/local，不新增永久禁用或每次GUI审批；产品应按“原窗口接续”表述，不记成所选管理账号已执行。

## 已知接线阻断，先解决再运行完整封装

1. 第二批改了 `Companion/Hub/main.go` 并新增 request lookup，**SOURCE/native构建输入清单及编译pin尚未闭合**。核 `Companion/Hub/SOURCE.json`、`windows/hub/`、Prepare-HubResources、build.rs 与验包输入，不能仅删hash检查以通过。
2. `WorkflowPreferences` 新增 snake_case `excluded_plan_types`、profile `service_tier/dispatch_code/not_after_ms`。Go `workflow_policy.go` 当前 strict decoder/consumer仍是旧字段；必须同步有效规则、manager snapshot、最终spawn。现存配置未写新字段不代表新保存路径可用。
3. 单次 execution 新协议只是拟定，**未实现**：optional `windowsExecution:{workflowRevision,bindingSHA256,overrides}`，在原create+lease bodyhash后追加域与binding；Go必须从权威本地prefs和native模型证据重派生，不能信客户端effective/hash。完整字段序在纯规则源码；savedtier后的 golden 为 `41a9feb4a5623db2e17b01ea2d26bb14e2cc061bd285f26ffa313adcc861ecc7`。Mac子代理preset/sandbox等旁支仍有实际差距，当前standard规则不能代表这些能力已齐。
4. `workflow_reader.rs::read_evidence` 当前 raw Tokio child/kill_on_drop忽略最终wait结果，不能直接当新增Bridge完整owned-process清理证据。需复用已存在owned路径或最小收紧，不重造runner。
5. 第二批 native测试驱动、cfg(windows)类型/依赖、实际App+Python+Hub组合与最终SOURCE/pin/验包mandatory集合尚未完成。不要让“0 tests/ignored”算通过。
6. Mac2d8失败只定位到 `scripts/LocalProxyCleanupRetryFixture.swift` 首次打印CHECK23后SIGTRAP；自动LLDB同binary28通过。原日志缺首次具体assert/backtrace，仍待根因，勿删断言/加无依据sleep/抹原失败。

## 构建、验证与封装入口

先在干净、任务所属Windows checkout核上述未完项；这里的命令是接手入口，**本次收尾不执行**。读固定toolchain/lock，先比较重复安装，复用现有依赖。Go cache/tmp放同一任务工作卷；大写入先核真实卷余量/共存峰值，保留50GiB准入/20GiB保留，不清未知系统缓存。

```powershell
git fetch origin
git switch codex/windows-parity-local-1029v2
git pull --ff-only
git rev-parse HEAD
git status --short
python -B windows/companion/prepare.py
python -B windows/companion/prepare.py --verify-only
pwsh -NoProfile -File windows/scripts/Invoke-ReleaseReadiness.ps1 -Version 3.0.0 -OutputDirectory "$PWD/.local-artifacts/handoff-1031v1" -PlanOnly
```

补完并独审后，使用同一入口去掉 `-PlanOnly` 执行完整readiness及打包；不要从外部使用 `-SkipValidation` 冒充门禁。它最终调用 `scripts/build-windows-release.ps1` 生成 MSI 与 NSIS EXE，读取真实内部版本，外部正式文件/说明按 MMDDvN。实际版本选择遵循既有产品版本，不仅改文件名。

需要保留的验证：

- `cargo fmt --all -- --check`、真正 non-test/release check、Rust workspace、web合同/build及受影响所有真实组件定位器截图；原断言/阈值不能降低。基线图是本地任务证据不提交，受影响新基线须目视与无update复验。
- 既有三强制Rust native case：`commands::task_hub::tests::windows_settings_roundtrip_through_pinned_hub`、`provider_pool::tests::windows_pinned_helper_empty_start_stop_and_dpapi_roundtrip`、`accounts::native::runtime_setup_tests::windows_selected_runtime_roundtrip_and_owned_probe`。
- 第二批需新增真实原生驱动：`desktop_owner::native_tests::windows_original_owner_pipe_contract_and_no_replay` 与 Companion `native_tests::cases()` 的实际入口；后者当前不是可直接执行的 #[test]。合成unsigned peer只用于test，不作为official签名验收。
- Go Hub11/provider38现有native声明与新lookup/规则应按真实最终列表冻结；现有两次独立冷启、任务所属PID/出生/完整cleanup及所有资源身份继续保留。
- 既有 `.github/workflows/release-windows.yml` 两种升级job及 `windows/scripts/Test-InstallerUpgrade.ps1` 必须保留原2905品牌迁移、真实1603回退、owned恢复、foreign保留、卸载，再做固定862同版本reference段；测试仅允许一次性GitHub-hosted Windows，不能在用户机器运行。
- 两升级基线的精确资产hash已锁在脚本。MSI actual ProductVersion/ProductCode/UpgradeCode、DB936/summary1252/language1033及7个原中文资源 source→CAB/NSIS→安装后hash均真实读取；新installedexe必须等两实际包共同唯一AMD64 App，不能只信自报manifest。
- 接手后按最终commit/tree/实际CI checkout/工具SHA冻结，不混用任何旧head日志。已有offline验包工具是Mac任务外置证据，不在源码树；Windows可复用仓库readiness/upgrade脚本产出原回执，回传供同源独立验包，不能自称外置工具已执行。

## 最终提交与回传要求

完成剩余源/调用方/原生验证后，用精确路径暂存，提交并推送，更新PR40的最终范围和证据。然后上传**对应同一最终源码**的：

1. MSI、NSIS EXE；
2. 每个安装包的 SHA256 文件及 manifest（source commit/tree、产品内部版本、资源/主程序hash）；
3. readiness、两个升级baseline、真实native/冷启/清理和独立验收回执；
4. 可点击的源码commit/PR、CI run、独立draft或artifact下载链接，说明尚存平台限制。

上传前比较目标当前版本，重复成果不覆盖。默认独立draft/pre-release；不移动stable/latest，不合并PR。若尚有必需门禁失败，明确交付候选/未接受，不通过换包名、删tests或重放Unknown推进。

## 保护边界与现有Mac交付

- 不修改 `~/.codex/auth.json` 或全局 `config.toml`，不切号、不调整反代/安全开关，不操作真实账号/模型/重置卡/通知发送。
- 不安装、重启或替换用户当前App；不要连接用户真实pipe做测试。必要安装/升级仅在上述隔离runner。
- Mac166 [独立draft](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/untagged-240c20af6823a6d3893d) 已交付：DMG 213426583B，SHA256 `9b6a102bb318975ebe541ddec0af30c239cdd74bdebb03fa113832167be14dde`。当前安装仍164，签名不等于公证。8张公共cache混合预览不当纯fixture或今日事实。
- Mac四处推荐工作树改动与candidate165 App/current166/旧包远端回退/正在用cache继续保护。此前已精确删165本地DMG+checksum213425934B，观测free变化含并行，不重复清理/计数。
- 本次交接不删除任何未完源码、当前编译产物或诊断证据，不建新监控/聊天/额外CI。若push自动触发现有workflow，只记录；Windows接手者先核已有run，再决定必要验证。

## 本次小结证据索引

完整本机证据位于任务 `evidence/`（不随源码提交，不含用户凭据）。此处固定摘要供跨机核对：

- 859 package独审：`852619990209089e057b76420e30817b4ae26524da0c8b2fad1f76c3a0643a68`；native独审：`c99fa1d0b6491de98870de735b74b73e0a853113c89774b4026d6da86f0f85fe`。
- 2d8 v11输入冻结独审：`5eaacf314e94cf7d6e6bd232d0ec167454cf182998bd13d5b9ff385da1910a3d`；web双轮日志：`94bb6f63e24beac8216d596ea6e39427fbb69ad31e5c5cfdcb698ddce6c1eded`。
- Companion共享资源v2独审：`16ec6ac17a772d536400229f7167f98dcf3a8ffe52c1b7a4ee4469b41f2fa5e4`；安装叶独审：`c3c5fee7c7118e56b81f032e3612f11d5dc31c45be9b01b0a6f02d38876b4565`。
- owner caller v2独审：`b30c666be9c90dedf0bb500e4c40839883ca0e1926ca277cb1c84e48c628f86f`。原peer运行、父UI和自动接续不在此通过范围。
- savedtier v2候选：`e85dac611fd48899c712ce144bffd2f6081ba8888cfc323e94343ac9b2406cf5`；最终独审 `370ec6ba0ce06fefd6227708cdecbc40e8bf644be9535f84c743a35ac95097b8`。原16通过后仅改schema反例真实key并复验1项；不称又跑过16。精确最终源码以随本页101文件清单为准。
- 两作者已停止且无自有后台：new_account归集回执 `f9c9616f4561710a2585a22f2707fd039cc1f8473c5ac5b01363606eb36ef04e`；Windows reviewer归集回执 `a8d1627e802e7b1c1077aa190351fcfb5a22e23ec750eacb52876451735f3967`。Agy三个拟新文件均未创建；最后Bridge execution adapter一行未写。
