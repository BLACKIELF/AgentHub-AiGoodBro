# Windows 交接与源码集成 · 0921v4

相较 0921v3，本版增加账号目录管理及其回归测试。沿用原交接入口与分支，
不重复覆盖已安装的 Mac 9.6.5（54）。

相较 0919v1 路线图，本次提供 Mac 9.6.5（54）的可读取源码与 Windows 采集修复；
不把只读 Dashboard 宣称为完整账号管理器，不更换 Windows 技术栈。

## 集成关系

- 分支：`codex/release-windows-0921v3`，起点 `main@3cf5c1b`。
- PR #5、#6 已合入 main，#7 已关闭；本分支保留这些结果并整合 #3 头提交 `4f4972a`。
- PR #10（`d6268e0`）是朋友独立提交的 .gitattributes 方案，本次不重复提交、不全仓 renormalize。
- 原 Mac 工作目录保持不动。正式合并仍以 main 为集成入口；这不是另建长期分叉的 win_dev。
- 朋友可以在本分支固定提交上验收采集修复；不要从仍停留在早期实现的历史分支打包后称为功能对齐版。

## 本次替 Windows 先完成的部分

### 0921v4 · 账号目录纵向切片

- 主页面关联已有 Codex home、设置不含邮箱/路径的备注、逐位排序、确认后移除关联、切换查看来源。
- 元数据保存在 Next 的 settings.json；兼容未包含 profiles 的旧配置。先写临时文件并原子替换，再更新内存与来源代际。坏 JSON 或不兼容旧配置拒绝覆盖，失败不关闭编辑器。
- 额度查询子进程使用所选目录的 CODEX_HOME；不修改父进程环境或系统 Codex 配置。更换数据源时清空旧展示，拒绝迟到结果，普通刷新不移动行。
- 账号列表 DTO 只有字符串 id、备注和正在查看标记；不输出目录路径。“正在查看”不表示已验证登录身份。
- 移除只删除元数据关联，不删除目录、不注销登录，也不改变正在使用的配置来源。
- 附带修复：跨平台导入的 rollout 路径统一处理两种分隔符；旧 Rust 重试测试改用合成目录，避免扫描测试者真实 Codex 数据。

**这不是完整 P1，也不是受管账号仓库。** 尚未实现登录、凭据导入/保护、系统账号切换、
跨进程并发写保护、退出/重启验证、事务回滚。目录管理需单个 app 实例使用。
不能因为“能切换查看”就打开自动切号或认为多账号登录已完成。

朋友可先接这组文件：core profiles/atomic_settings、Tauri profiles/app_state/settings、
Web ProfilesPanel/useUsage；下一批先补 Windows 凭据安全存储及身份验证，再接手动切换事务。
不要双方同时改这些文件；PR 合并或固定提交验收后再分工。

### 0921v3 · 采集链修复

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

## 验证记录与边界

- 0921v3 的提交 0b18d0d：GitHub CI 全部通过，包括 macOS、Windows Rust、Web、PowerShell 5.1/7。
- 0921v4：本机通过 Rust workspace 69 项测试、Web 24 项测试、生产构建和浏览器 12 项测试（包含 4 项账号目录交互及 3 个新定位器截图断言）。截图仅保存在本地 .local-artifacts。
- Windows CI 的最终结果以本次 PR 为准；在 Mac 编译和测试通过不冒充 Windows 实机结果。
- 未在 Windows 原生窗口验证目录选择器、真实账号官方额度、安装/升级，以及 issue #8 的 UIA Document。
- TypeSafe 复核入口：`node scripts/review-typesafe-windows-0921v3.cjs --run`，在已有密钥的终端显式调用。一次 6 个窄问题，含反例；默认 dry-run、不自动重试、不进入 app/CI。尚无本轮模型回执时，不标为模型审查通过。
- TypeSafe 按技能用于“源码是否支持某个具体说法”的辅助判断；编译、回归、身份安全和放行仍由确定性检查负责。
