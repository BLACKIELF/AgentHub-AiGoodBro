# 非 Codex CLI 模型选择能力 · 0911v1（只读）

范围：现有 adapter、本地帮助文案与 `agent_cli_capabilities.py`。未改任何 adapter，未联网抓付费接口，未启动真实 CLI。

结论：GUI 直达模型/强度选择器只对 Codex（`ExecutionPreferenceControl`）成立。其它 provider 本轮只应保留 T06 摘要行与既有说明，不要造选择器。

| Provider | GUI 能否指定模型/强度 | 启动参数/配置证据 | 本地帮助 | 建议 |
|---|---|---|---|---|
| Codex | 能。账号卡与执行面板已有档位控件 | 受管 `next_dispatch_activity.py plan/run` | 档位说明在 `ExecutionPreferenceControl.modeInformation` | 保持现有控件 |
| Grok | 不能。GUI 打开官方 `grok`，argv 只有 `login --oauth` 或空 | `LocalCLITerminalLauncher` `.grok`：无 `--model`。`agent_cli_grok.py` 有 `--model` 但 `agent_cli_capabilities.py` 生产 `run.supported=false`（`grok_quota_bridge_missing`），只承认精确 `grok-4.6-build` | 工作区摘要只讲登录隔离，不讲 GUI 选模型 | 引导增强；不要做选择器 |
| OpenCode | 不能 | 启动 argv 为 `auth login` 或空；模型需在 CLI 内按「服务商/模型」选择。XDG 隔离，无模型参数 | 「模型需在 CLI 中按服务商/模型选择」 | 摘要行 + 现有说明 |
| WorkBuddy | 不能 | 打开 bundled TUI；注释写明 positional 会被当成 model prompt，因此不传模型名。capabilities 的 run 模型固定 `deepseek-v4.1-flash`，免费顺序另有 hy4/hy3，无自动回落 | 「打开后选择账号可用的模型」 | 摘要行；选择发生在 CLI 内 |
| ZCode | 不能 | 默认环境 `login` / `tui --settings`；链接环境明确不可启动。capabilities：`zcode_managed_runner_missing` | 「登录成功不等于指定模型可用」 | 摘要行；不做选择器 |
| Claude Code / Kimi / MiMo / Gemini / TRAE | GUI 启动本身 unsupported（除 TRAE 桌面） | `LocalCLITerminalLauncher` 对这些 kind `throw .unsupported`。capabilities 目录不含这些产品 | Claude/Kimi/MiMo/Gemini：关联配置目录。TRAE：只开个人版桌面 | 保持现状；模型选择不在 GUI 范围 |

## 证据路径

- `Sources/CodexUsageWidget/Services/LocalCLITerminalLauncher.swift`
- `scripts/agent_cli_capabilities.py`
- `scripts/agent_cli_grok.py`（`--model` 存在，生产 run fail-closed）
- `Sources/CodexUsageWidget/UI/LocalCLIWorkspaceView.swift` `workspaceSummary`
- `docs/local-cli-model-availability-0911v7.md`（逐模型证据，不是启动选择器）

## GUI 直达 vs 引导增强

- **直达**：仅 Codex 已有稳定偏好对象与保存回读。
- **引导增强（本轮已做 T06）**：卡片摘要「可用模型 N · 已验证 M」，点击展开既有清单。不把摘要当成可派单授权。
- **不要做**：非 Codex 的 ExecutionPreferenceControl 克隆、把 `agent-cli --model` 接到 GUI 按钮、或把 documented free facts 显示成可点选启动模型。
