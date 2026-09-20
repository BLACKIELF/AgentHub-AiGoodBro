# Windows 交接与源码集成 · 0921v3

相较 0919v1 路线图，本次提供 Mac 9.6.5（54）的可读取源码与 Windows 采集修复；
不把只读 Dashboard 宣称为完整账号管理器，不更换 Windows 技术栈。

## 集成关系

- 分支：`codex/release-windows-0921v3`，起点 `main@3cf5c1b`。
- PR #5、#6 已合入 main，#7 已关闭；本分支保留这些结果并整合 #3 头提交 `4f4972a`。
- PR #10（`d6268e0`）是朋友独立提交的 .gitattributes 方案，本次不重复提交、不全仓 renormalize。
- 原 Mac 工作目录保持不动。正式合并仍以 main 为集成入口；这不是另建长期分叉的 win_dev。
- 朋友可以在本分支固定提交上验收采集修复；不要从仍停留在早期实现的历史分支打包后称为功能对齐版。

## 本次替 Windows 先完成的部分

1. 修正 issue #8 的主窗选择：枚举任务进程的顶层窗口，只接受可见、无 owner、类名精确为 Tauri Window 的候选。忽略 Tao Thread Event Target；没有候选继续等，多个候选报错，不猜测、不激活、不延长期限。
2. 回归覆盖冷启动的隐藏主窗、其他进程、owned popup、错误类名和多个候选；直接编译调用生产 C# helper，并检查等待循环接线。
3. preflight 分清 cargo 缺失与固定 MSVC 工具链缺失；支持显式 SDK 路径、注册表和系统目录发现。
4. 可选原子 JSON 诊断仅写入本地 .local-artifacts 新文件，不覆盖既有结果；修正测试函数导入作用域，接入 PowerShell 5.1/7 CI。

尚未解决：朋友同时报告的 WebView2 UIA 树缺少 Document，属于另一层阻塞。
正确 HWND 不代表 DOM 断言已通过；不要因此关闭 issue #8，也不要通过加长超时或删除断言掩盖它。

## 固定的产品契约

延续 [0919v1 路线图](WINDOWS_PARITY_ROADMAP_0919v1.md) 的 P1 账号核心优先级，
不要求朋友在 P1 同时追赶所有 Mac 外观变化。

| 能力 | 当前 Mac 参考 | Windows 后续验收要求 |
| --- | --- | --- |
| 账号持久化 | CodexProfileStore | 原子写入、明确错误、失败保留旧状态，凭据不进 WebView |
| 手动／自动切换 | CodexAccountActions、UsageStore | 同一身份/占用/验证/回滚路径；未知状态停止写入 |
| 排序与备注 | ResetCardPresentation、AccountOrderSheet | 保留已保存顺序，置顶显式改变，改名和刷新不能偷改顺序 |
| 模型与调度 | ExecutionPreferenceControl | 默认展开；所有保存和应用到全部都返回真实结果，失败不关闭编辑器 |
| 重置消息 | ResetUpdatesBanner | 概要置顶、近期最多 3 条、完整年份；公告不等于个人额度到账 |
| 维护者消息 | PublisherMessages | 固定公开源、首次基线、过期过滤、最近 3 条、默认不通知、不承诺送达 |
| 推荐 | HomeSkillShelf | 一句话简介与安装指令，交给 Codex 确认，不静默安装 |

账号核心未验收前不加入自动切换、暖号、重置卡消费等高风险动作。
本分支的空公告源尚需合入 main，支持公告的新客户端也需分发；源码推送不等于全部用户已收到消息。

## 分层验证

在仓库根目录执行：

```powershell
.\windows\scripts\tests\Test-NativeWindowSelection.ps1
.\windows\scripts\tests\Test-NativeVisualCaptureWorkflow.ps1
.\windows\scripts\Capture-NativeVisuals.ps1 -PreflightOnly
```

最后一层必须在 Windows 真机或可交互桌面中继续执行既有
`Test-NativeVisualCaptureCoverage.ps1`，分别记录 HWND 选择、前台保护、UIA Document、
定位器、截图与清理结果。脚本单元测试不能代替此层。

本机执行结果与 CI 状态见本次 PR 的验收记录；Windows Rust 和原生 API 不在 macOS 上冒充通过。
