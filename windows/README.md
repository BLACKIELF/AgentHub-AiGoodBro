# Codex Account Manager Next for Windows

该工作区保留上游 `codexU` 的 Rust crate/CLI 内部名称，但桌面产品、安装标识、安装包和缓存目录已切换到独立 Next 命名空间，不覆盖旧版 Windows App。

当前 checkout 已包含 Phase 1/2 的本地数据管线和 Phase 4 Dashboard UI：

- Rust reader 读取本机 Codex transcript、`state_5.sqlite` 和 automation 元数据
- Tauri IPC、额度状态、用量、任务、项目、Skills 和 AI Leadership Dashboard
- 中英文设置、Light/Dark/System 外观和六套语义 palette catalog
- Windows 原生 exact-HWND、后台不抢前台的视觉采集 workflow

当前实现仍是只读 Dashboard，没有账号档案、登录或账号切换命令。后续不再以模糊的“下一阶段”追赶移动目标；功能所有权、固定基线和 P0–P5 顺序见 [Windows 功能对齐路线图](../docs/windows-port/WINDOWS_PARITY_ROADMAP_0919v1.md)。

任务快照读取并展示：

- 线程标题、项目路径、模型、归档状态、Git 信息
- SQLite 读取失败时自动降级为 JSONL-only
- 标题优先使用 `title`，为空时回退到 `preview`，展示前归一化并截断到 48 个字符
- 工作区只展示路径尾名，automation 优先使用配置中的 `name`

## 外部贡献 · 0916v1

相对历史说明：Windows PR 统一提交到 `main`，贡献范围、分层验收及共享资源依赖见 [CONTRIBUTING.md](../CONTRIBUTING.md#windows-contributions)。完整检出仓库；稀疏检出须同时包含 `windows/`、`Resources/LeadershipBadges/` 和 `Resources/Palettes/`。下方下一阶段列表是待办，不代表已承诺的跨平台对齐计划。

## 快速开始

Windows 工作区使用 MSVC ABI。首次在当前检出目录开发时，安装并设置项目级 toolchain override：

```powershell
rustup toolchain install 1.97.1-x86_64-pc-windows-msvc --profile minimal --component rustfmt
rustup override set 1.97.1-x86_64-pc-windows-msvc
```

该 override 只作用于当前 `windows/` 目录，不修改全局默认 toolchain。仓库不提交
`rust-toolchain.toml`，因为只写版本号时，rustup 会沿用用户的 default host，在配置为
GNU 的 Windows 环境中意外选择 GNU ABI，并额外要求系统提供 `dlltool.exe`。

```powershell
cd windows
cargo build --release --locked

# 使用默认路径（~/.codex/state_5.sqlite）
$env:RUST_LOG="info"
.\target\release\codexu-probe.exe --summary

# 指定 Codex 数据根
.\target\release\codexu-probe.exe --codex-root "$env:USERPROFILE\.codex" --summary
```

## 验证

```powershell
# Rust workspace tests
cargo +1.97.1-x86_64-pc-windows-msvc test --workspace --locked
```

### 原生视觉验收

Dashboard 的正式 Windows 本机采集入口会构建真实 Tauri release 应用，并执行一次
最大化、exact HWND 的采集运行。Overview 仅采集一个顶部 viewport；Tasks、AI Leadership、
Usage 与 Skills 使用动态编号的 panel segments；Projects 仅采集一个最大化的首个 viewport。
采集实例保持最大化，但以 non-activating background tool window 运行：不改变用户当前前台窗口，
并从任务栏和 Alt-Tab 排除；正常启动 Codex Account Manager Next 的窗口行为不变。
截图、日志和 WebView2 临时数据只写入
Git 忽略的 `.local-artifacts/`；不得提交、上传、复制进公开报告或从公开文档链接。
公开证据必须使用全合成 fixture，具体边界见
[`docs/windows-port/README.md`](../docs/windows-port/README.md)。当前仓库不包含可公开的 Windows 运行态截图。

测试分三层：

1. `-PreflightOnly` 只检查依赖、脚本语法、窗口策略和输出边界，不构建、不启动窗口。
2. `Test-NativeVisualCaptureWorkflow.ps1` 检查采集 workflow 的静态契约，包括最大化、non-activating、保留前台窗口、后台 Z-order、tool window、任务栏/Alt-Tab 排除和精确 capture 参数。
3. `Test-NativeVisualCaptureCoverage.ps1` 构建并启动真实 Tauri release 应用，覆盖各 Dashboard surface，验证 exact HWND、真实截图、前台窗口未改变和最终进程清理。

```powershell
cd ..

# 不启动 app 的快速检查
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Capture-NativeVisuals.ps1 -PreflightOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\tests\Test-NativeVisualCaptureWorkflow.ps1

# 真实窗口覆盖测试（会构建、启动、截图并清理）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\tests\Test-NativeVisualCaptureCoverage.ps1

# 正式采集
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Capture-NativeVisuals.ps1

# 只采集 Skills 的聚焦运行
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Capture-NativeVisuals.ps1 -Surface Skills
```

Coverage 运行速度不是当前验收重点；重点是它不会抢焦点或覆盖用户正在使用的窗口。运行边界、DPI 说明、精确 PID 清理规则和人工验收清单见
[`docs/windows-port/WINDOWS_NATIVE_VISUAL_WORKFLOW.md`](../docs/windows-port/WINDOWS_NATIVE_VISUAL_WORKFLOW.md)。

## 工程结构

```text
windows/
├── AGENTS.md                              ← Windows 专属代理规则
├── Cargo.toml / Cargo.lock                ← Rust 工作区
├── README.md
├── apps/
│   └── codexu-tauri/                      ← Tauri 桌面应用
│       ├── src-tauri/                     ← Rust 后端（app_state / commands / tray）
│       └── web/                           ← React + TypeScript + Vite 前端
│           ├── src/                       ← 界面、hooks、i18n、类型、工具
│           └── tests/                     ← 契约测试与视觉断言
├── crates/
│   ├── codexu-core/                       ← reader / 聚合 / 模型
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── models/
│   │       │   ├── mod.rs
│   │       │   ├── usage.rs
│   │       │   ├── runtime.rs
│   │       │   └── leadership.rs
│   │       └── readers/
│   │           ├── mod.rs
│   │           ├── common.rs              ← 聚合、缓存、成本估算
│   │           ├── codex_state.rs         ← state_5.sqlite 读取
│   │           ├── codex_transcript.rs    ← Codex JSONL + 元数据富化
│   │           └── claude_transcript.rs   ← Claude Code JSONL（保留，待激活）
│   └── codexu-cli/
│       ├── Cargo.toml
│       └── src/
│           └── main.rs                    ← codexu-probe 只读诊断 CLI 入口
└── scripts/                               ← Windows 原生视觉采集与测试脚本
    ├── Capture-NativeVisuals.ps1
    ├── native-visual-capture/
    └── tests/
```

## 下一阶段（只记录，不实施）

- 定义 prompt-like session 标题、完整路径和敏感片段的脱敏策略。
- 对默认蓝紫、一套冷色和一套暖色做 Light/Dark 原生视觉矩阵。
- 补齐 Settings、空数据、错误状态和长中文标题的原生验收。
- 补齐 Windows 安装包代码签名、更新器与真实机器发布验收。
