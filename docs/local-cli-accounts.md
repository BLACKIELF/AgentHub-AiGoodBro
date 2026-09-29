# 本机 CLI 账号、额度与原生入口 · 0929v2

在工作台顶部选择本机已安装的 CLI。默认环境自动出现；“关联账号”可添加另一个已登录的配置目录，分别命名、刷新或取消关联。取消关联只移除 Next 的记录，原 CLI 文件保留。

| CLI | 本版读取范围 | 边界 |
|---|---|---|
| Codex | 原有独立账号、官方额度、重置卡和官方余额 | 保留现有身份核验与调度占用保护 |
| Grok | 原生 CLI OAuth 对应的官方 billing 额度 | 使用原生文件锁自动续期；失效登录仍需官方登录 |
| Kimi Code | 原生 OAuth 对应的 Coding 额度窗口 | 会话到期时按官方协议和锁续期，原子保存后重读；不需要重新打开 CLI |
| Claude Code | 原生 OAuth 官方额度 | 默认环境可静默读取自身钥匙串项；不回退到其他账号 |
| OpenCode | OpenCode Go 额度 | 缺少 OpenCode Go 只表示该额度源未连接，不代表其他服务商未登录 |
| WorkBuddy | 原生额度接口暂未接通 | 登录与 TUI 使用 WorkBuddy 自带 CLI，不替换为外部 codebuddy/cbc |
| TRAE SOLO | 国内个人版当前登录的官方积分与额度 | 读取对应桌面会话并复核身份；没有该会话时不回退或猜测 |
| Gemini CLI | Code Assist 返回的模型额度 | 需要有效的原生登录与项目信息 |
| MiMo | 原生账号元数据 | 原生额度接口暂未接通；提供官方用量页入口 |
| ZCode | 当前账号个人 Coding Plan 与 Start Plan 模型额度 | 绑定当前产品区和精确账号；完整显示 Token 数量，过期或尚未生效的赠送额度不计入 |

ZCode 从本机 v2 加密存储核实当前产品区与账号。Coding Plan 使用该账号专属密钥；Start Plan 使用当前会话的官方 JWT 与设备标识，独立查询账户级 billing 接口，因此没有 Coding Plan 不代表没有 Start Plan。两个接口独立处理失败，完成后再次核对账号与凭据。首页和详情展示模型、剩余 / 总量、百分比及精确到期时间，不把 Tokens 当作积分或美元。不回退使用旧配置镜像、其他产品区或其他账号；关联目录和团队计划仍未支持。

## 原生启动说明

- Grok：登录入口运行官方 `grok login --oauth`。每个托管账号有独立 `GROK_HOME` 与 `GROK_AUTH_PATH`，同时清除继承的 API key/token 环境。普通启动复用同一隔离路径。
- OpenCode：登录入口运行官方 `opencode auth login`，普通入口打开 TUI。关联目录须保持 XDG 的 `根目录/.local/share/opencode` 结构；Next 从该结构派生独立的 config/data/state/cache 根，不回退读取默认身份，也不继承常见付费服务商 API key。模型在官方 CLI 中按 `服务商/模型` 选择，Go 额度不能代表其他服务商。
- WorkBuddy：查找系统与用户 Applications 文件夹中的 WorkBuddy.app，只使用其 `Contents/Resources/app.asar.unpacked/cli/bin/codebuddy`，并由同一 bundle 的 `Contents/MacOS/Electron` 以 `ELECTRON_RUN_AS_NODE=1` 执行。已核对的内置 CLI 版本为 2.137.1。Next 将 `ACC_PRODUCT_CONFIG_PATH` 指向同一 CLI 目录的 `product.json`，将 `CODEBUDDY_CONFIG_DIR` 与 `WORKBUDDY_CONFIG_DIR` 指向该 profile 的 `.workbuddy`，并设置 `WORKBUDDY_DATA_FOLDER_NAME=.workbuddy`、`DISABLE_AUTOUPDATER=1`。登录按钮只打开官方 TUI，用户在其中输入 `/login`；不会把 `login` 当作模型提示发送。需要调用时在官方 CLI 中选择账号可用的模型。
- ZCode：只使用 `/Applications/ZCode.app/Contents/MacOS/ZCode` 配合 `Contents/Resources/glm/zcode.cjs` 和 `ELECTRON_RUN_AS_NODE=1`。已核对桌面版本 3.11.2、内置 CLI 0.16.5；公开帮助包含 `login`、`tui`、`--prompt`、`--mode`、`--settings`。默认环境登录运行 `login`，打开运行 `tui`，设置文件明确指向 `~/.zcode/cli/config.json`。桌面模型配置 `~/.zcode/v2/config.json` 与 CLI 配置独立，因此 OAuth 成功或默认模型出现都不能证明用户指定模型可调用。关联环境仅展示额度，不提供未经证明的隔离启动。
- TRAE SOLO：只识别“应用程序”中的官方个人版桌面并打开它。不会查找或启动独立 `traecli`，也不添加付费 API 回退。

路径会在写入 Terminal 私有启动包装前完成规范化、symlink 组件拒绝和 shell quoting；带空格或单引号的合法目录不会被拼接成可执行 shell 片段。未知登录、模型或额度状态均保持未知/未接通，不以命令退出码冒充成功。

进入页面、重新激活应用或点击“刷新额度”时可重新读取；有效结果缓存 5 分钟，普通失败冷却 60 秒，限流冷却 15 分钟，同一账号不重复发起请求。官方 CLI 登录文件变化时清除该目录的旧额度并重读，请求期间变化则丢弃旧响应。刷新失败时仅保留身份未变的该账号上次有效快照，并明确标记。没有数据表示“暂未读到”或“暂未接通”；不会推算成 0。能够确认相同身份时会提示共用额度，没有可靠身份标识时不猜测。

Codex 的“官方余额”保留官方接口返回的数值。当前接口未提供币种、点数单位或换算关系；本版不将它标为美元，也不把余额和重置卡相加。缺失值不显示为零，来源与时间可在余额说明中查看。

新适配器使用原生 Swift 和现有的有界网络、文件读取器。请求有总时限与响应大小上限，禁用 Cookie、重定向和自动重试。Next 只保存关联名称及配置目录，不复制这些 CLI 的登录凭据。

0927v5 已完成协议、异常响应、启动参数和账号隔离回归；安装版实测 Kimi 与 Grok 的额度显示。Kimi 通过官方 CLI 的 `/usage` 正常更新原有会话，再由 AiGoodBro 读取；没有发起模型任务。其他供应商的当前连接限制见 [本地集成记录](ai-goodbro-2.0-0927v5.md)，不把合成测试写成真实额度接通。[来源与许可](third-party-cli-notices.md)
