# Windows 接手与封装交接 — 1102v1

当前继续完善 Windows，沿用本页稳定路径。**候选源码已推进，最终同源 Windows 原生验收和 MSI / EXE 交付尚未完成。** 本页约需 5 分钟阅读。`WINDOWS_HANDOFF_SOURCE_1031v1.json` 是 1031 的历史 101 文件快照，不是当前源码清单；当前来源以本页所在提交、CI 实际 checkout 和最终发布 manifest 为准。

## 当前目标与边界

- [PR #40](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/40)，分支 `codex/windows-parity-local-1029v2`，PR 目标分支 `codex/windows-parity-1029v1`。继续在同一 PR 整合，不强制 checkout/reset，不合并或发布 stable/latest。
- 对齐基线为已提交 Mac165 `ad74ecd040d498f590c889081ce7c2c8fc13f00b`，遵循 [Windows 路线图](WINDOWS_PARITY_ROADMAP_0919v1.md) 与 `windows/AGENTS.md`。不从 Mac 未提交工作树复制实现，不新增合同之外的产品能力。
- 完成源码、调用方和相应验收后，交付同一最终源码的 MSI、NSIS EXE、SHA256、source commit/tree、资源 manifest、readiness、双升级和独立验包回执，上传独立 GitHub 草稿发布并回贴 PR。
- 当前授权包含该任务的修复、精确路径提交/推送、现有 hosted CI 与草稿发布。真实账号、模型、消息发送、用户机器安装/升级和真实官方聊天操作不属于测试范围；不修改全局认证或安全配置。

## 已完成的源码推进

| 范围 | 当前实现 | 证据及仍需验证的边界 |
| --- | --- | --- |
| 工作流与独立 Session | A–Z 派单码显式登记；旧数字 profile selector 与旧 journal 兼容；model/effort/service tier、savedFast、plan 排除和 notAfter 通过权威本地偏好与 native evidence 重新派生，Hub 最终门禁已接；独立 profile/home/session 路由 | 已有合成/host 测试及审查；当前原生 E2E 必须实际执行，不能以 schema 或文件存在认定运行通过 |
| Python 与 Companion | 固定 Python probe/选择；事务式资源安装；private Receiver → AppBackend → Hub；未知 create/approve 查询状态、不重 POST；正常退出保留未知 owner | 原生驱动已接入 workspace gate。受限同用户 token、精确子测试、proof 与整个 Job 为空都必须成功；本机 host 检查不能代替 |
| Agy 与客户端进程 | typed OwnedConsole、suspended → Job → domain → resume；cleanup 未确认时保留 owner/lease；Agy probe 与客户端路径已接 | host provider-client 10/10、console 4/4；Windows fakeCLI 与完整 Job 清理依赖当前原生 CI。无真实 provider/model 调用证据 |
| 原聊天操作 | native context + fresh owner snapshot；持久一次性 action journal；手动接续/中断、取消与未知状态保护、UI/IPC 接线 | 原 owner caller 的 host 测试 24/24；官方 Windows 26.1027.3384.0 固定包协议已静态核对，真实官方 peer/原聊天交互仍未验。ActiveSystemScope 不证明 GUI 当前账号身份 |
| M05 额度刷新 | 复用账号维护 monitor；自动/1/3/5/10/30 分钟频率；前后台自动间隔；停止、身份和操作占用门禁 | 核心 21 项与频率界面通过本地验收。真实官方账号刷新未执行 |
| N02 微信原聊天关联 | 显式绑定/授权版本；新消息时间门禁与持久去重；在实际 owner 写入前重核取消；只回传精确新 turn 的 final answer；未知不重试 | 本地核心、文字和 UI 用例通过；未扫码、发送真实消息或调用模型。Windows native owner 链路仍需验收 |
| P04 账号/反代同步 | 两入口共用 persisted preferences；原子单账号参与/优先/最后使用/排序；显式 Pro false 保留；删除前要求退出反代 | 已过 scoped core/Node 与组件测试；窄屏新增相机入口的预期位移经人工核图后无更新复跑通过 |
| M06 1% 暂停与原任务续做 | 完整当前任务批次先落盘；同一原生 maintenance lease 下逐 turn 中断并确认；完整新鲜 idle roster 后切换；用户显式继续原任务；未知结果保留且不重发；清除记录保留原聊天与运行任务 | 本地策略 15 项、journal 9 项、提交 hook/竞态 4 项、实际 Manager+lease 轮换绑定 1 项、完整 roster 1 项及 UI 2 项通过。自动恢复当前窗口选项仍不可用，不由显式续做测试冒充 |
| U03 主界面长截图 | 实际 WebView2 全高 PNG；单次捕获锁、尺寸/解码界限、DOM/滚动恢复、原生保存、原子写入与读回；固定 isolated native capture witness | 本地 PNG/状态 7 项、前端截图 3 项通过；Windows-only CDP 编译、实际全高输出与恢复顺序必须由新增原生 harness 验证 |

本批前端整体合同测试 157/157、TypeScript/Vite 构建已通过。本地 locator 截图按变更逐张审阅并无更新复跑；这些结果不表示最终 Windows 安装版本或真实账号已验收。

## 当前流水线与历史交付

本批五项功能收尾前，已推送的编译修复基线为 `2f284de7f75c7a047613738dd19be0fc6e811e8d`：

- [CI 41443907093](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/runs/41443907093)：Windows web 双轮及 native-visual 两次独立冷启动/清理成功；focused Companion E2E 实际运行 1 项，但启动隔离子进程时报 Access is denied，0 passed / 1 failed。记录时 macOS 尚未结束。
- [package 41443907094](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/runs/41443907094)：同样在 focused E2E 启动处失败，readiness 标记 rust-tests 失败；仅上传 readiness artifact，没有 MSI/EXE。
- 当前候选增加受限令牌启动路径修正和确切 API/错误诊断，保持 Medium、同 SID/session、隔离环境与 Job 门禁；尚未获得 Windows 实跑修复证据。当前候选的新功能不在上述编译修复基线内。后续提交必须用自己的 exact-head CI、实际 checkout tree、安装器及回执验证，不能沿用旧 head 的绿灯。

[win1031v1 历史草稿](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/untagged-5b31e62e90da54e887c4) 对应较早 `86263b0c`，保留作为历史交付；[Mac166 草稿](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/untagged-240c20af6823a6d3893d) 是另一个平台的交付。均不证明本候选已完成，不重复覆盖或把旧包改名当新包。

## 继续执行

先保留本机未提交工作、读取本分支已有运行，避免重复 dispatch 或推送取消仍能提供结果的运行。确认 checkout 后执行项目现有入口：

```powershell
git status --short
git rev-parse HEAD
python -B windows/companion/prepare.py
python -B windows/companion/prepare.py --verify-only
pwsh -NoProfile -File windows/scripts/Invoke-ReleaseReadiness.ps1 -Version 3.0.0 -OutputDirectory "$PWD/.local-artifacts/windows-1102v1" -PlanOnly
```

完成源审与本地定向验收后，使用同一入口去掉 `-PlanOnly`；最终调用 `scripts/build-windows-release.ps1` 构建 MSI 与 NSIS EXE。不要通过 `-SkipValidation`、削弱断言/阈值或重放未知请求跳过失败。内部产品版本以实际安装器内容为准，正式交付说明和文件版本使用 MMDDvN。

保留以下门禁：

- 精确编译工具版本、格式检查、真正 non-test/release 构建、Rust workspace、前端合同/build/实际组件截图双轮。基准图及真实数据截图仅留在本地验收目录，不提交。
- `windows/scripts/Invoke-RustWorkspaceTests.ps1` 准备 fakeCLI 和已验证 Python。focused `windows_python_receiver_app_backend_routes_two_sessions_and_status_after_disconnect_does_not_repost` 必须明确 `running 1 test` 和 `1 passed`；exit 0 或 0 tests 不计通过。
- 原生核心 gates 包括 Hub settings roundtrip、provider helper/DPAPI/Job、selected runtime probe、original-owner pipe no-replay、Companion receiver、Python/AppBackend 两 Session 路由以及 owned fakeCLI whole-Job cleanup。合成 unsigned peer 仅是测试输入，不能冒充官方签名验收。
- 两次独立原生冷启动、五个 native surface、所有资源身份、截图全高/fixture 像素/`restored|saved` witness 和任务所属进程完整清理。失败保留相应日志，不将资源准备成功当作原生 UI 通过。
- `release-windows.yml` 的 MSI 与 NSIS 双升级保留 2905 品牌迁移、实际 1603 回退、owned 恢复、foreign 保留、卸载及固定 862 同版本 reference。安装和升级只在一次性 hosted Windows runner 执行。
- 安装器实际 ProductVersion/ProductCode/UpgradeCode、Unicode MSI 元数据和原中文资源从源码到 CAB/NSIS 再到安装后的 hash 都要读取；两个安装包须含同一个唯一 AMD64 App。新增 Companion、Hub、provider 资源同样逐文件核验。

## 提交与回传

冻结精确源码清单后，由同一发布 owner 审阅暂存列表并提交；禁止全目录混入依赖、构建、截图或日志。推送同一 PR 后保存 actual checkout commit/tree 和所有必需 job 的结果。

只有对应同一最终源码的安装包、双升级和独立验包均通过，才上传独立草稿发布。上传前与目标当前版本比较，重复内容不重复写入；上传后读回文件名、大小、SHA256 与下载链接，并将 commit、CI、draft 下载和验收摘要回贴 PR。任何必需项仍失败时，保持候选/未验收状态，交代具体剩余事项。

本机 `evidence/` 内既有 offline 验包工具可复用；它不在源码树内，跨机接手者只能声称自己实际执行过的检查。需要回传原始 readiness、升级和 native 证据供独立验包，不能仅提供自报 manifest。
