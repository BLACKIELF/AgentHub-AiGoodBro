# AiGoodBro 2.0 · 0927v1

相较 0926v4：按用户要求直接复用 Token Monitor v0.62.0 的完整 Electron 界面与功能代码，替换此前的原生近似界面。**2026-09-27 已将本地 9.6.13(62)／AiGoodBro 2.0 · 0927v1 覆盖安装至 `/Applications/AiGoodBro.app`。** Electron 辅助程序命名崩溃、CSP 拒绝 inline style 导致的 Home 品牌图片放大已修，原版 Home、Dashboard、Trends 已实机显示真实数据并检查布局。新增1%暂停、切号与原任务续接及全局新图标通过最终编译和完整自检。安装后宿主与嵌入用量模块启动成功；最后一轮UI自动化工具断连，未取得About与新控制项的最终目视结果。

## 界面与功能

- 原版 Dashboard、Home、Tool、Status、Device、Model、Project、Session、Limits、Trends，以及原设置、价格、订阅、自定义路径、导出和 Hub 模块随 AiGoodBro 打包。
- 原版 Edge Dock 的 CSS、几何、交互、字体与 60 个提供商 SVG 保留原字节。常规圆环为 42 px、Agent 图标为 17 px；紧凑模式沿用原来的 34 px／14 px。品牌文字和应用图标使用 AiGoodBro。
- 原版用量窗口直接由 AiGoodBro 的菜单栏和“用量看板”入口打开。主工作台、账号、任务、自动化和公开重置预告功能保留；托盘提供返回这些页面的入口。
- 正常启动、退出、升级和登录时启动由 AiGoodBro 统一管理。上游独立更新器停用，避免把 AiGoodBro 更新成另一个产品。随包运行不依赖另行安装的 Token Monitor。
- 用量设置使用独立的 AiGoodBro 数据目录。首次语言跟随 AiGoodBro，之后保留用户在用量界面保存的中英文选择。
- 现有 Codex 管理账号通过私有本机连接接入额度面板。宿主核对存档身份与当前凭据，存在歧义时不关联；切号通过 AiGoodBro 现有任务、身份、互斥、备份、验证和回滚流程。

- 全局应用品牌替换为用户定稿的人物头像；旧五款图标选择迁移为单一批准图标，供应商 Agent SVG 继续保留原版。
- 新增“剩余 1% 自动暂停并换号”和“换号成功后自动继续原任务”，可关闭自动续做、改用手动按钮。准确暂停清单先持久保存；未知结果不重发，已完成任务跳过。过程与验证记录见 [1%暂停切号](desktop-quota-pause-0927v1.md)。旧提醒开关不会自动授予中断任务权限。

## 验证与边界

最终宿主构建、完整签名、33组原生自检和39项打包检查通过；原生自检包含7组暂停与11组续做协议模拟，新增检查覆盖私有连接请求、复合账号身份和重复身份拒绝。原版资源逐字节比对及 ASAR 完整性检查见 [包内核对报告](../.local-artifacts/token-monitor-native-0926v1/desktop-companion/parity-report.md)。这些结果不能代替真实账号登录、在线 Hub、通知或切号验证。

安装前检查只有一个正式 AiGoodBro 副本；原子覆盖后主程序、ICNS、ASAR与候选逐项一致，`codesign --verify --deep --strict` 通过；Codex auth/config 安装前后摘要相同。主程序 SHA-256 `cbfc6bcb72a889674942bb510923113cc039bc9fde6da58ef1c3e98a4cda351a`，ASAR `b7b9f4954ae8e100e6e1050672e1adf935c8f693a6e17172a7de0c083a9d078f`。见 [安装回执](../.local-artifacts/token-monitor-native-0926v1/desktop-companion/install-final-receipt.json)、[自检日志](../.local-artifacts/token-monitor-native-0926v1/desktop-companion/final-self-tests.log)。

原版9个视图路由已逐一返回成功；Home、Dashboard、Trends 已实际检查。安装版进程路径位于正式应用内，私有连接ready/trayVisible均为true；CUA native pipe断开且reset后未恢复，应用仍运行，未把该工具故障算作界面验收通过。Edge Dock 已保存右侧/始终显示设置，自动化工具只绑定到同名隐藏peek窗口，尚不能提供rail/detail的目视验收结论。

仍有两项明确限制：

1. macOS 原生 WidgetKit 扩展尚不可用。本机没有 AiGoodBro 所需的 Apple Team／App Group 签名资料；原作者扩展已归档到不会被系统注册的位置。右侧 Edge Dock 和菜单栏浮窗不属于该扩展。
2. Antigravity Google OAuth 登录仍沿用此前审查后的禁用适配。本地用量解析保留，不宣称其 OAuth 与官方包完全一致。

用户后续要求的七套原生主题仍按 [既有清单](ai-goodbro-2.0-0926v4.md#后续阶段七套主题逐套落地)逐套验收，不计作本轮已完成。未推送 Git、未发布 2.0 公共安装包，未清空废纸篓。

## 构建和回退

`make build` 默认将固定版本的完整桌面模块放到 `AiGoodBro.app/Contents/Helpers/AiGoodBro Token Core.app`。当前打包器针对已核验的 macOS arm64 官方运行时；构建机需提供该运行时，默认读取 `/Applications/Token Monitor.app`，可用 `TOKEN_MONITOR_DESKTOP_RUNTIME` 指定其他只读输入。`TOKEN_MONITOR_DESKTOP_DMG` 可额外指定官方 SHA 固定的 DMG。原安装应用和 vendor 不作为可写工作区。

`BUNDLE_TOKEN_MONITOR_DESKTOP=0` 仅供旧原生路径回归；不能用该构建声称完成本次原版界面集成。安装前验证整个嵌套签名、包内 ASAR 和实际进程路径。回退时保留已有账号目录与 AiGoodBro 设置。
