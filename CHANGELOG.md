# Changelog

## 0921v5 - 2026-09-21（Windows 分目录额度）

相较 0921v4，不改 Mac 9.6.5（54），为 Windows 账号目录新增手动额度读取：

- 每行独立读取该 Codex home 的额度，不需要先切换查看或产生聊天记录。
- 只显示返回的 5 小时/每周/每月窗口；未读取、查不到和缺少窗口不冒充 0。
- 保存读取时间；刷新失败、记录超过 5 分钟或已到重置时间时，旧值明确标成上次记录。
- 读取只由点击触发，不轮询接口、不自动重试；并发上限 2，失败/取消释放名额。
- 返回前重新检查目录关联，界面校验 ID；移除后的迟到结果不能恢复旧行。仍不是登录身份验证或账号切换。
- TypeSafe Jev 1.13.0 对固定源码快照一次复核 10 个问题：9 个预期约束均判定支持，故意加入的错误说法判定不支持，判断置信度为 0.87–1.00。它只作为证据一致性辅助，不替代测试、真机或人工审查。

## 0921v4 - 2026-09-21（Windows 账号目录）

相较 0921v3，不改 Mac 已安装的 9.6.5（54），新增 Windows 可独立验收的目录管理：

- 关联已有 Codex 数据目录、备注、逐位排序、移除关联、切换查看用量；不是登录导入或系统账号切换。
- 目录元数据原子保存，失败保留旧内存状态和编辑输入；损坏或不兼容的旧设置不被默认值覆盖。
- 官方额度子进程绑定选中目录，数据源变化清空旧展示；迟到响应不覆盖新目录。
- 目录路径不返回账号列表 WebView；移除关联不删除原目录或凭据。
- 增加 Rust 回归和浏览器交互/截图断言；Windows 真机登录、切换、安装与 UIA Document 仍待验收。见 [集成说明](docs/windows-port/INTEGRATION_0921v3.md)。

## 0921v3 - 2026-09-21（源码集成）

相较 0921v2，本次不改变 Mac 9.6.5（54）的产品行为：

- 同步本机验收过的 Mac 源码、可移植推荐资源与空公告源；修正 Swift 格式门禁。
- Windows 采集按任务 PID、可见性、owner 和 Tauri 类名选择窗口，拒绝 Tao 消息窗口与多个候选；不增加等待时间。
- 补齐 Windows preflight 依赖诊断、可选原子 JSON 回执、SDK 发现和 PowerShell 5.1/7 回归。
- 保留朋友 PR #10 的独立换行符改动，不做全仓换行重写。Windows 账号切换仍未实现；交接和验证边界见 [0921v3 集成说明](docs/windows-port/INTEGRATION_0921v3.md)。
- 仅源码分支与 PR，不创建二进制 Release、不自动发布面向用户的公告。

## 9.6.5 / 0921v2 - 2026-09-21（本机安装版）

相较 9.6.4 / 0921v1：

- 账号按保存顺序显示，仅主动置顶优先；排序按钮一次移动一位，不再用拖拽驱动滚动。临期仍显示标记，但不改变位置。
- 模型设置的单账号、全部账号、自定义档位和恢复默认统一验证与保存回执；失败不关闭编辑器，账号消失不再假报成功。模型与调度默认展开。
- 同类账号名称编辑失败保留输入；其他 CLI 改名不再移动账号顺序。
- 重置历史只显示最近 3 条，保留完整年份与来源；日历和近期消息入口分开，刷新状态不再隐藏。
- 轻唤加入推荐区，和 Skill 一样提供一句话指令及 Codex 跳转。Oracle 文案改为调用浏览器，请网页版 GPT 最好的模型复核或出方案。
- 新增维护者公告的固定 GitHub 源、最近三条、过期过滤、初次基线、通知开关与去重。本地空源未公开发布，不声称现有全部用户已经收到。参见 [消息发布说明](docs/publishing-messages-0921v2.md)。
- 完成 32/32 原生自测、排序／改名等回归、真实窗口验收与本机覆盖安装；保留旧包备份。未提交、推送或发布新版。

## 9.6.4 / 0921v1 - 2026-09-21（本机安装版）

相较 9.6.3 / 0919v2：

- 修复图表高度反馈包含旧视口的问题，短内容可以收缩，不再每次回报额外撑高页面。
- 原生日期范围同时约束热图、日期输入和当前选中日；周对齐留白不再暴露范围外记录，保留累计明细。
- 滚轮转交仅限当前窗口内可见且未被遮挡的图表，其他窗口和控件仍由各自处理。
- 单独的趋势页使用整行宽度，不再沿用概览的双列留出空位。
- 增加 VM 和真实 WKWebView 回归；保留重置概要置顶、Skill 卡片在前、总消耗在后的布局。TypeSafe 本轮凭据尚未恢复，不将本地修复归为其模型贡献。

## 9.6.3 / 0919v2 - 2026-09-20（本机安装版）

相较 9.6.2 / 0919v1：

- 用量页的 WKWebView 改为只负责渲染，关闭内层横向/纵向滚动并把滚轮交给首页主滚动容器；网页按真实内容高度回报，不再用固定大高度制造空白。
- 90 天概览采用紧凑 7 行热力图与更宽趋势图；选中日期下方显示真实 Token 总量、工具占比条形图、SVG 构成图和图例，点击与键盘选择保持联动。
- 首页重置消息收口为窄概要；历史消息改为当前页面内联展开，不再创建独立消息 NSPanel。近期公告仅限过去 30 天内、非未来且 DTO 可验证的记录，所有时间保留完整年份。
- 更新为 9.6.3（52）/ 0919v2；完成 32/32 自测、真实界面滚轮验收、签名/资源核验与本机覆盖安装。本版未创建 Git tag、GitHub Release、提交或推送。

## 9.6.2 / 0919v1 - 2026-09-19（本机安装版）

相较已安装的 9.6.1 / 0915v5（50），保留工作区现有功能并补充：

- 暖号偏好迁移只读取持久域，启动参数不写成永久授权；发送前保存请求身份，模糊失败等待新窗口证据，结果保存失败保留跨进程占用。
- 旧账号 ID 补写不再覆盖已有身份；未绑定额度须重新核实，晚到回调和重复结果不能污染新身份或降级成功。
- 重置消息置顶，默认只显示概要；推荐 Oracle / Handoff / TypeSafe AI 安装入口在前，账号和总消耗在后。随包提供可移植 Skill，通过 Codex 草稿确认安装，不静默覆盖。
- macOS arm64 最终优化包完成 32/32 自测、签名/资源验证和本机覆盖安装；未公开发布。证据、TypeSafe 适用范围与回退说明见[审计交付记录](docs/warmup-audit-0919v1.md)。

## 9.5.22 / 0912v1 - 2026-09-12

相对 9.5.21 (35)，修复真实数据与操作边界：

- 重置公告保留事件原意、来源和时间；通道去重、投递状态、主线程生命周期与通知设置交互收口。飞书对未返回的 Pro 5 小时窗口显示未知，不推断为不限额。
- 修复 CC Switch schema 18/DST 历史，明确完整累计、历史累计、未知和真实零；图表支持失败与重试，窄窗卡片保留可读宽度。
- 自动切换接入共享事务与最终门禁；终端结束依赖完整进程证据，Pro 20x 配置映射不再依赖错误的工作目录。
- 登录永久失效分类和额度子进程 EOF 处理更准确；统一真实悬浮窗入口与资源打包来源。
- macOS 源码预览，尚无二进制 Release 或公证包；本次实机进出全屏已验证，设置弹层、拖动、实际账号切换、重置卡消费和外部消息送达仍未验收。详见[版本说明](docs/release-notes-v9.5.22.md)。

## 9.5.21 / 0911v3 - 2026-09-11

相较 9.5.20 (34)，本版完成当前版产品集成与对外名称统一：

- 用户可见的 macOS 应用包、执行文件、菜单/窗口名和打包资产统一为 AiGoodBro；界面短名 AH，工作台名 AgentHub。
- 主窗口恢复原生全屏（绿色按钮与 ⌃⌘F）；状态栏浮窗与任务概览仍为辅助窗口。
- 合入受管 CLI 入口、Grok 重置观察、独立监控选择、官方登录服务层、主窗口五项工作台、账号浮窗、设置/菜单栏外观、逐模型可用性离线回执桥，以及安装空闲保护与双名迁移。
- 隔离 bundle ID、Application Support、defaults、Keychain 和账号目录保持兼容；旧名 `CodexAccountManagerNext.app` 仅用于升级识别。
- macOS 源码预览；无二进制 Release 或公证包。详见[版本说明](docs/release-notes-v9.5.21.md)。

## 9.5.20 / 0911v2 - 2026-09-11

相较 9.5.19 (33)，本版整合此前候选并修复验收发现的问题：

- 首页跨平台账户统一排序，支持固定第一位和72小时内到期红框；Grok 缺失卡字段时保持未知。
- 原生任务概览加入真实运行状态，归档不再冒充完成；请求取消、超时和迟到回调按代际失效。
- 任务完成、切换、额度变化和重置卡新增使用对应通知；Telegram/企业微信已接入独立配置与真实事件来源，默认关闭。
- 调度取消意图不能被迟到的运行或成功覆盖；Hub 终态同步保留真实来源。WorkBuddy 实际传入免费候选模型参数并清除无关环境，Codex run 复用受管入口。
- 严格校验消息响应，限制在途发送和捕获输出；回执存在、成功退出与用户验收分别表示。
- macOS 源码预览；无二进制 Release，未运行 Windows 检查。详见[版本说明](docs/release-notes-v9.5.20.md)。

## 9.5.19 / 0911v1 - 2026-09-11

相对 9.5.18 (32)，9.5.19 (33) macOS 源码预览新增：

- 软件显示改名 AiGoodBro，主页工作台名为 AgentHub；公开仓库名切换为严格大小写 `AgentHub-AiGoodBro`。
- 保留 `CodexAccountManagerNext.app`、同名执行文件、bundle ID、DMG 名、安装位置及原 profiles/support/cache/defaults/hotkey 命名空间。只读更新检查优先新仓库名，新地址返回 404 时兼容旧仓库名，不迁移账号、凭据或偏好。
- 主页提供专业／极简模式；专业默认展开，极简可选总览、账号卡片或最多四个自定义模块。使用引导移到主页前部。
- 模型和强度使用完整原生菜单控件，编辑面板按实际内容确定高度。
- 官方余额取整显示，发生取整时标注约值；说明保留精确原值、来源与时间，修复长数字精度和说明按钮命中区域。
- Grok 官方账号读取补全客户端请求头；接口缺失字段仍显示未知。
- 任一已知订阅窗口耗尽时，阻止自动和手动暖号，异步占用检查后再次核对；官方窗口恢复前只读刷新。Skill 补充所有点数和付费回退账号的停用规则。
- 本版提供源码与文档，尚无二进制 Release；多 CLI 登录与真实调用尚未全部通过。详见 [0911v1 候选记录](docs/release-notes-v9.5.19.md)。

## 9.5.18 / 0910v3 - 2026-09-10

- 默认 Home 展示已安装平台；Grok 增加官方登录、独立账号环境和打开 CLI 入口。
- 关联已有配置使用文件夹选择，拒绝将应用包用作账号目录。
- 登录验证与额度字段缺失分开显示；保留已有 Next 运行与储存命名空间。

## 9.5.17 / 0910v2 - 2026-09-10

相对 0910v1：

- 新增已安装 CLI 的图标切换、独立账号关联与额度读取；MiMo 和 ZCode 原生订阅额度明确保留未接通状态。
- 三个执行档位可修改名称、主模型、强度与子代理组合；原生终端、CLI 运行器与配套 Hub 校验最终参数。
- 首次引导检查现有 Python/Codex 并准备配套 Skill；不内置外部运行时，已有 Hub 和个人配置保留。
- 飞书增加简洁字段选项；账户卡显示自己的官方余额、绿色重置卡数量与最近到期时间。
- 新增三次确认的重置卡入口，发送前重读身份与卡片、共用占用锁；不确定结果保留同一密钥。本版未执行或测试重置流程。
- 修复参与时段“添加区间”后列表被压缩不可见；增加明确高度和滚动到新行。
- 修复进程退出与描述符清理、原子回执、缓存有界读取、整数溢出和账号取消关联后的缓存释放。
- 本地 macOS 候选，尚未发布 GitHub Release；详见 [0910v2 记录](docs/release-notes-v9.5.17.md)。

## 9.5.16 / 0910v1 - 2026-09-10

- 卡片改为并排显示 5 小时与 7 天额度，压缩留白和按钮区；820 点窄窗可并排三张，详细暖号记录与重置信息仍可在详情查看。
- 飞书显示调度编号与账号备注；连接测试、手动切换、测试重启和自动低额度事件分别说明原因，低额度提醒只列实际命中的条件，保留小数避免误判。
- 修复真实桌面切换后的当前账号标记滞留：验证过的身份切换独立更新快照，迟到的旧身份结果不能覆盖新账号。

- 飞书连接可在首次引导中完成，已有凭据可显式授权。旧式 macOS 钥匙串操作统一串行控制弹窗权限：后台读取保持静默，保存、授权和移除异步执行；取消授权不会显示已连接。ad-hoc 版本升级可能需要重新授权。
- 重置消息默认开启，通过本机通知提醒，无需飞书、不消耗账号额度；首次建立基线，不补发历史。飞书折叠为可选转发，旧队列可按有界分页恢复。
- Desktop 切换立即显示准备状态与取消入口；磁盘、进程与并行额度校验移到后台，显示退出到验证的进度。来源和目标身份原子占位，普通切换不隐式强退。
- 修复原生 Terminal 启动：使用已校验绝对路径、优先独立 CLI，保留执行偏好与隔离环境；启动回执、进程指纹、退出状态和保存重试共同维护占用。
- “参与调度”旁新增时钟编辑器，支持允许/排除时段、星期、时区和跨午夜；Skill 与配套 Hub 检查新任务准入，刷新和暖号不受时段限制。
- 保留最近暖号成功与失败历史，修复保存失败提示；重登增加维护占用，修复旧账号缺失 account ID 的验证。登录子进程未确认退出时不释放占用。
- 两种 Mac 安装包附公开调度 Skill、脚本和中文说明，只含虚构停用配置；升级保留本机映射、个人策略和已有设置。运行验收边界与签名信息见 [0910v1 发布记录](docs/release-notes-v9.5.16.md)。

## 9.5.15 / 0909v4 - 2026-09-09（已本机部署，源码与图片更新）

- 相比 0909v3，新用户默认中文、列表、系统主题、7 天剩余额度菜单栏、⌘U 与 Astra / Low / 标准速度；保留已有设置与账号参与选择。
- 卡片额度数字不再逐卡缩小；工作台、单账号和菜单栏均按身份匹配共享占用，排除调度账号也可显示维护状态。
- 在真实调用结束后完成纯占位、Hub 重启与 Next 原位覆盖；249 个 Hub 任务 ID 保留，24 项设置与 9 个账号偏好一致，接单开关恢复且 9 个维护占位全部释放。
- 26 组应用自检、22 项 Python 协调测试、跨语言锁互通与九账号布局通过。中英文 README、生成封面和原生演示图更新。
- 本版未发布安装包，未以真实模型任务、切号或通知测试进行验收。详见 [0909v4 更新说明](docs/release-notes-v9.5.15.md)。

## 9.5.14 / 0909v3 - 2026-09-09（候选阶段，改进已合入 0909v4）

- 相比 0909v2，加入 Skill 共享占用的准备/运行/待验收状态和暖号预约；成功请求确认已处理的重置信号，修复满额时重复立即暖号的路径。
- 统计刷新不再统一禁用无关编辑；新增同一本日期问题日志入口，优先派单说明与新 Skill 的选号行为一致。
- Skill 0909v3 已更新；Next 26 组应用自检、21 项脚本回归及 Python/Swift 互通通过。当前 Next/Hub/CLI 没有重启或接管；真实运行效果待部署验收。
- 详见 [0909v3 更新说明](docs/release-notes-v9.5.14.md)。

## 9.5.13 / 0909v2 - 2026-09-09（已本机部署，未发布）

- 相比 0909v1，修复飞书自动通知同步读取钥匙串拖住主线程、使额度刷新与暖号一起停止的问题；启动时的配置检查也改为后台读取。
- 读取 5 秒超时，最多保留 16 项等待读取。系统调用返回过晚时丢弃结果，不补发旧通知；读取后的发送仍复核通知开关、事件选择及配置版本。
- 新增隔离回归，覆盖主线程响应、超时、积压上限、过期结果、恢复读取、正常发送与关闭后取消。测试使用模拟钥匙串与拦截传输，不发送真实通知。
- 详见 [0909v2 更新说明](docs/release-notes-v9.5.13.md)。

## 9.5.12 / 0909v1 - 2026-09-09（已本机部署，未发布）

- 相比 0908v6，修复满额度窗口的官方 reset 随读取滑动时自动暖号被无限推迟；根据上次成功时间维持 5 小时 / 7 天维护周期，保留 8 秒余量。
- 失败后至少 5 分钟重新核验再重试；账号忙碌时保留计划，缺少映射不再让其他账号一起停摆。仅接受明确成功且未被后续或同刻失败覆盖的额度快照。
- 两种暖号继续独立于参与调度和旧会员日期。周额度仍可用时移除旧的 5% 暂停线；额度已用尽、身份不明或官方拒绝仍阻止请求并继续恢复判断。
- 退出调度可同步同一已核实身份的多个 Hub 目录，保留原编号；加入时遇到多目录歧义仍拒绝。同步反馈和中英文暖号说明与实际行为一致。
- 26 组自检、76 项调度同步测试通过；本机观察到自动最小请求成功及稳定的官方 5 小时 reset。完整 7 天自然周期仍待观察。见 [0909v1 更新说明](docs/release-notes-v9.5.12.md)。

## 9.5.11 / 0908v6 - 2026-09-08（已本机部署，未发布）

- 相比 0908v5，两项暖号、低额度提醒、系统通知、飞书通知、额度重置和 Reset 卡提醒默认开启；明确保存的关闭选择保留，新账号继续默认参与调度。
- 新增四步使用引导，支持跳过、进度续看、重新进入和全部开启；先说明暖号额度消耗，再引导设置通知。
- 系统通知开关与 macOS 授权分开显示，启动不弹授权；飞书未配置时保留开启偏好并显示待配置。账号、任务、额度和发送门禁保持生效。
- 系统已拒绝通知或已完成授权时，引导提供系统通知设置入口；重新进入通知页或应用回到前台后读取最新授权状态。
- 详见 [0908v6 更新说明](docs/release-notes-v9.5.11.md)。

## 9.5.10 / 0908v5 - 2026-09-08（已本机部署，未发布）

- 相比 0908v4，维护启动参数暂停的暖号与通知会明确显示暂停原因，受影响开关不可误改；调整另一暖号开关时不会把临时覆盖值保存为永久偏好。
- 自动化中心允许分别选择 5 小时与 7 天的提醒阈值，默认仍为 5% / 10%；候选额度、身份、任务时效及一小时提醒间隔保持不变。
- 新增默认关闭的 macOS 低额度通知，手动开启后才请求系统权限；通知只包含剩余百分比，提交状态不等同于屏幕送达。
- 本轮采纳项与运行验收见 [0908v6 汇总说明](docs/release-notes-v9.5.11.md)。保留既有单实例、共享事务及调度同步修复。

## 9.5.9 / 0908v4 - 2026-09-08（已本机部署，未发布）

- 相比 0908v3，启动时先取得单实例运行锁；账号设置、额度、会员资料、重置计数和调度同步共用状态事务，避免旧实例覆盖新数据。
- 构建前检查目标包是否仍在运行；存在对应进程时在删除或写入前停止，提示使用单独的候选目录。
- 运行期间状态文件丢失或变为无效内容时阻止覆盖；添加和删除账号按最新状态处理，回滚结果不确定时保留可能仍被引用的账号目录。
- 退出调度后保留停用编号，重新加入时沿用原字母；新映射补全预检字段及整数优先级，主界面隐藏停用编号。
- 调度刷新结束显示实际取得新鲜额度的账号数，保存失败不再显示刷新成功。
- 本机替换与验证边界见 [0908v6 汇总说明](docs/release-notes-v9.5.11.md)。Desktop 实时控制和登录失效账号仍有待验收项，不能把部署完成写成全部功能验收完成。

## 9.5.8 / 0908v3 - 2026-09-08

- 相比 0908v2，不参与调度的账号也按全局开关执行 5 小时与 7 天暖号；移除调度编号后，沿用 Hub 中现有账号目录核验空闲状态，额度和会员日期继续维护。

- 相比 0908v1，过期会员日期会在账号额度刷新后自动重查：通过官方凭证刷新再读取日期，保留身份隔离与 Hub 空闲检查；失败退避，已核查但官方日期未变时明确显示结果。

- 相比 0907v3，5 小时、7 天官方窗口到期后默认刷新额度，不受暖号开关、调度参与或额度耗尽影响；休眠错过到期时间时补查。
- 到期读取失败或仍返回旧的耗尽窗口时，至少间隔 60 秒再次检查；新读取失败会阻止使用旧快照暖号。
- 首次安装默认开启两项暖号；升级保留已有开关，包括旧版没有保存过的默认关闭状态。
- 保留脱敏的登录失效错误分类，避免官方 401 只显示为通用请求失败；本版本用于本机替换验收。

## 9.5.7 / 0907v3 - 2026-09-07

- 相比 0907v2，补齐英文主界面、菜单、模型设置、按钮说明、主要操作反馈及飞书通知，日期与 Token 单位跟随界面语言。
- Pro 等账号缺失官方 5 小时窗口时，大字改为“—”，保留小字解释，不把未知数据显示为无限。
- 周额度归零时，卡片、顶部概览及菜单栏的 5 小时可用额度同步归零；只调整展示，不改写官方快照，周额度恢复后还原原始 5 小时值；正数低于 1% 时显示 `<1%`。
- 统一 CLI 主入口与更多菜单的禁用条件；优先标记明确为“仅保存偏好”，保留原有参与调度同步与安全门禁。
- 当前公开截图统一使用英文原生 2× 演示界面；26 组自测、69 项离线同步测试、格式、兼容性及内存门禁通过。仅推送源码，不安装、不切号、不部署 Hub 或发布安装包。

### English

- Completed English workspace, menu, model-setting, action-feedback and Feishu notification copy; dates and token units follow the interface language.
- Replaced oversized missing-5h text with a neutral dash and a short explanation. Unknown quota is never advertised as unlimited.
- Displayed zero 5h availability when Codex's weekly quota is exhausted, consistently across cards, the overview and menu bar, without rewriting official snapshots or affecting Claude.
- Aligned CLI entry-point safety guards, clarified saved-only priority preferences and refreshed the public English native screenshots.

## 9.5.6 / 0907v2 - 2026-09-07

- 相比 0907v1，主界面新增可记忆的「列表 / 卡片」选择，默认保留垂直列表；柔和渐变卡片以大字突出 5 小时额度，随窗口宽度排列多列，全部账号功能和顺序共用。
- 点击「编辑」后显示账号右上角三条横杠，支持列表纵向、卡片横向拖动排序和 180ms 过渡；松手后保存一次，区域外松手或 Esc 取消，保留右键与辅助功能上移/下移，遵循系统“减少动态效果”。
- 列表使用统一对齐列：账号在左、两条额度上下排列居中、模型与操作在右顶对齐、红色重置提醒在左下；终端改为纯图标，保留分组间距。
- 顶部统计收为可展开摘要；完整账号资料、更新时刻、会员信息与历史暖号保留在“详情”，临近会员到期和其他异常仍在主行可见。
- “7 天额度不足”、登录失效、暖号失败等关键字标红加重，其余文字保持中性；仅从摘要中合并已在额度栏显示的相同暖号时间，不隐藏不同的预约时间或未知状态。
- 增加两种布局、三宽度、浅深色九账号视口与完整截图回归，以及布局保存、拖动草稿、顺序落盘、重复时间、正常日期颜色与关键字测试；操作安全门禁不变。
- 本轮由主线程直接实现与复核，不派发其他账号；仅更新源码，不安装、不切号、不部署 Hub 或发布安装包。

### English

- Kept vertical account rows as the default and added a persistent, optional card grid with shared account actions and order.
- Added edit-only three-line drag handles, cancellable single-save reordering, a short Reduce Motion-aware transition and accessible Move Up/Down actions.
- Aligned list identity, stacked quotas and top-right controls, kept spacing between groups and made the terminal button icon-only.
- Collapsed statistics and read-only account history behind native disclosure and detail controls, while keeping actionable warnings visible.
- Highlighted critical status phrases in red and bold; deduplicated only warm-up dates already shown as official reset dates. Added compact-layout and text-presentation regression coverage without changing scheduling or account policies.

## 9.5.5 / 0907v1 - 2026-09-07

- 相比 0905v4，主窗口默认缩至 980 × 700；账号身份、额度和操作分组对齐，压缩卡片与概览高度，保留原有功能位置和窄窗换行。
- 右上角新增原生 PNG 长截图，包含完整滚动内容并保持当前展开状态；九账号、三宽度、浅深色和保存/取消/失败分支均有合成测试，超限拒绝而非静默裁切。
- 旧额度响应不再覆盖新状态；同刻响应仅补全字段，成功优先于失败，避免 Reset 历史回退或重复计数。
- 调度同步在写入前核对当前身份、新鲜成功快照与同账号镜像；校验和备份三份配置，逐文件原子替换并检测竞争写入，保留未知或不可读的恢复数据。69 项离线同步测试纳入 `make test`。
- 保留 0905v4 的暖号与默认关闭的飞书提醒；额度桶标识缺失时只建立基线，不误报恢复或 Reset 卡增加。
- “优先派活”只保存偏好，当前 Hub 尚不消费此标记；本次不修改或重启 Hub，仅推送源码，不发布安装包。

### English

- Reduced the default workspace and card density while preserving feature placement and narrow-window reflow; added native, bounded full-workspace PNG export with nine-account coverage.
- Made quota observations monotonic, merged equal-time evidence without erasing known values, and preserved reset-count idempotency.
- Strengthened current credential and mirror validation, per-file atomic synchronization and recovery-data preservation; added 69 offline synchronization tests to `make test`.
- Retained opt-in warm-up and Feishu behavior, rejected unknown quota-bucket comparisons, and clarified that Hub does not yet consume priority preferences. Source-only update; no installer or Hub deployment.

## 9.5.4 / 0905v4 - 2026-09-05

- 相比 0905v3，飞书新增「额度重置提醒」和「获得 Reset 卡提醒」两个独立选项，默认关闭；启用后约每分钟读取官方额度。
- 仅在可信身份的新鲜官方数据确认窗口滚动、额度恢复或 Reset 可用次数增加时发送脱敏通知；首次同步、字段缺失、乱序响应和重复账号入口不会冒充新事件。本地 Reset 历史调整不触发通知，也不自动使用重置卡。
- 沿用官方重置时间后 8 秒的暖号预约与 Hub 空闲门禁，到期刷新和暖号后确认改用纯额度路径，避免等待本地用量统计。
- 到期时若遇到刷新、登录或账号操作重叠，保留待处理定时器并在 5 秒后重新检查，避免丢失本次到期刷新；不跳过原有暖号检查。
- 保留低额度提醒、Keychain、Webhook 允许列表、重定向禁用、原有账号隔离与手动切换路径。
- 本轮为本地源码迭代，未安装、未进行真实暖号或飞书发送、未创建 GitHub Release。

### English

- Added separate, disabled-by-default Feishu/Lark alerts for official quota restoration and increases in available reset credits, with minute-level quota polling when enabled.
- Baseline-only startup, verified identity, fresh observations and account-level deduplication prevent historical or duplicate alerts. Local counter edits never trigger a grant alert or redeem a credit.
- Reset-time warm-up and post-request verification now use quota-only reads, retaining the existing eight-second grace period and idle-state checks.
- A deadline overlapping a refresh or account operation remains pending for another check after five seconds, without bypassing warm-up validation.

## 9.5.3 / 0905v3 - 2026-09-05

- 重新设计设置界面：Next 品牌页头、五个一级分区与轻量页脚，取代继承的长表单和层叠卡片。
- 外观新增三种可点击主题预览；语言、透明度、动效、菜单栏样式及统计时区的小范围选项直接展示。
- 菜单栏预览与恢复默认放在同一区域；暖号独立成页，明确窗口规则、额度消耗与空闲保护；工作区集中数据来源、时区、窗口及快捷键。
- 保留全部设置、原有持久化键与业务回调；补齐偏好往返测试、五个分区的中英文标签检查及 20 张原生 Retina 2× 隔离预览。
- 保留 0905v2 的模型与思考强度一级菜单修正。
- 公开素材统一为 Next 品牌，24 张原生 2× 图片按序编号并附用途索引；新增 X、小红书、公众号发布稿与 Agent 安装指令。
- 当前产品设计与架构说明改为 Next 实际能力，清理过时的宣传素材；适用版权、许可证与内部兼容标识保留。

### English

- Rebuilt Settings around a Next-branded header, five direct sections and a quiet footer instead of the inherited long form.
- Added clickable appearance previews and inline segmented choices for common settings.
- Grouped menu-bar preview/reset, isolated warm-up controls with their safeguards, and consolidated workspace preferences without changing persistence or business callbacks.
- Added preference round-trip regression checks and 20 isolated 2× native previews across both languages and appearances.

## 9.5.2 / 0905v2 - 2026-09-05

- 模型和思考强度菜单直接展开选项，去除原生 Picker 自动生成的同名二级菜单；保留当前选中标记和键盘导航。
- 共享控件同步覆盖账号卡、单账号工作台和菜单栏；不改变即时保存、CLI 参数、Fast、恢复默认或应用到所有账号的行为。
- 检查其余菜单与选择器，保留目录、登录方式等有效选择，以及现有账号安全门禁。

### English

- Flattened the model and reasoning-effort menus while retaining native selection marks and keyboard navigation.
- Applied the shared-control fix to account cards, the single-account workspace and menu bar without changing persistence, CLI arguments, Fast, reset or Apply to All.
- Audited remaining selectors and preserved meaningful directory/login choices and account safety gates.

## 9.5.1 / 0905v1 - 2026-09-05

- 新增 GPT-6 Astra：六档 CLI 思考强度、Standard/Fast、主 Agent 与默认子 Agent 参数一致；已有设置和默认 Sol/High 保持不变。
- 重做共享模型选择控件：蓝紫色模型卡、原生分档滑杆、模型菜单、Fast 切换、恢复默认和多账号批量应用。
- 主窗口和菜单栏自动切换单账号专注布局；同身份入口去重，未知系统占位不误计为第二个账号，额度与任务对象保持一致。
- 升级浅色／深色表面、字号与信息层级，收拢单账号高级功能，改进窄窗口账号卡；移除独立巡检页和固定 Sol 配置基线，将过期／刷新失败提示并入账号卡，保留原有 Hub 门禁。
- Astra 本地 API 等效估算覆盖缓存读取、缓存写入、Fast 和长上下文；提升本地分析缓存版本以避免旧参考价残留。
- 完成上一阶段 macOS 结构整理：入口、生命周期、业务模型、读取与存储、设置和图表布局各归其层；统一 Swift 风格与 25 组纯测试入口。
- 新增隔离的 2× SwiftUI 文档预览，覆盖单账号／系统只读／多账号与浅深主题，修正旧设置截图入口会加载真实 UsageStore 的问题。

### English

- Added GPT-6 Astra with all six CLI efforts, Standard/Fast and consistent primary/default-subagent arguments, preserving existing defaults.
- Refined the shared model selector and introduced automatic single-account focus in the workspace and menu bar without weakening Hub gates.
- Improved contrast, narrow-window layout and identity-aware quota presentation; removed the duplicate Inspection page and merged snapshot-health notices into account cards.
- Added explicit Astra pricing, cache invalidation, regression coverage and isolated 2× production-view documentation renders.
- Consolidated the preceding macOS lifecycle/domain/service/UI refactor, Swift formatting and the 25-test runner.

## 9.4.2 / 0904v2 - 2026-09-04

- 修复暖号命令达到固定 90 秒后被强制结束、同时丢弃错误输出，导致长期只显示“暖号失败”的问题。
- 内置经 MIT 授权的 Codex-Manager 暖号协议层，改为直接向 ChatGPT Codex 后端地址发送最小 SSE 请求，并区分登录失效、限频、网络、超时与服务异常。
- 一次失败只阻止同一空闲额度窗口重复消耗；更新后的有效额度窗口会淘汰历史失败状态。暖号期间禁止切号、登录、删除账号或并发手动刷新。
- 账号卡与巡检页新增 Hub CLI 任务状态：待批准、准备中、工作进行中、取消中、待确认和终态反馈；缺少可信账号映射、新鲜 Hub 概览或检测到同别名活跃任务时，Next 会关闭该账号的终端入口。
- 暖号只接受正式 Hub 调度别名，不再用邮箱或账号名猜测；巡检映射改用 Next 自己的 Application Support 配置，并保留显式环境变量覆盖。
- 收紧发布隐私边界：默认调试日志去除账号消息、任务 ID、Bundle 路径与底层错误详情；终端命令用 `$HOME` 表达托管账号目录，诊断 JSON 与统计悬浮提示不再输出项目或 Skill 完整路径。
- 重写中英文 GitHub README，按当前可达功能补齐 Hub 门禁、执行偏好、暖号、安全切换、安装与隐私边界，并替换为隐私安全的 0904v2 Retina 2× 功能截图。

### English

- Fixed warm-up runs being force-terminated at a fixed 90-second deadline while their diagnostics were discarded, leaving a persistent generic failure state.
- Embedded the MIT-licensed Codex-Manager warm-up protocol layer to send a minimal SSE request directly to the ChatGPT Codex backend endpoint and classify authentication, rate-limit, network, timeout, and service failures.
- A failure blocks repeated consumption only within the same idle quota window; a newer active quota window supersedes the historical failure. Switching, login, deletion, and manual per-account refresh are blocked while warm-up is active.
- Added Hub CLI task state to account cards and inspection: approval, starting, working, cancellation, uncertain, and terminal feedback. Next disables terminal entry without a trusted mapping and fresh Hub overview, or when the mapped alias has active work.
- Warm-up now accepts only provisioned Hub dispatch aliases instead of guessing from email or account name. Inspection mapping uses Next's own Application Support configuration with an explicit environment override.
- Tightened release privacy boundaries: default debug output omits account messages, task IDs, bundle paths, and low-level error details; terminal commands express managed account homes through `$HOME`, while diagnostics JSON and analytics tooltips omit full project and Skill paths.
- Rewrote the Chinese and English GitHub README around currently reachable features, documenting Hub gates, execution preference, warm-up, safe switching, installation, and privacy boundaries with privacy-safe 0904v2 Retina 2× feature captures.

## 9.4.1 / 0904v1 - 2026-09-04

- 账号卡新增蓝紫色任务执行偏好入口，可分别选择模型、推理强度与标准/Fast 速度，并支持一次性应用到所有账号。
- “在终端中使用”生成的启动命令统一携带主模型、推理强度、默认子 Agent 与 Standard/Fast 参数；外部 Hub 派单器若从其他入口创建任务，需显式复用同一组参数。
- 执行偏好按账号持久化；不支持的模型组合、损坏状态或保存失败均会阻断变更并保留上一份有效配置。

### English

- Added a blue-purple per-account execution preference control for model, reasoning effort, and Standard/Fast speed, with a one-time Apply to All action.
- The generated terminal command carries the primary model, effort, default-subagent, and Standard/Fast parameters; an external Hub dispatcher must explicitly reuse them when creating work through another entry point.
- Preferences persist per account, while unsupported combinations, invalid stored state, and save failures fail closed without replacing the last valid configuration.

## 8.26.1 / 0826v1 - 2026-08-26

- 自动切换阈值调整为 5 小时剩余 `<= 5%`、7 天剩余 `< 10%`；候选账号对应触发窗口仍需 `>= 30%`。
- 每个账号新增“参与自动切换”范围开关；关闭后不会消耗其自动切换额度，但继续参与 7 天暖号与官方随机重置暖号。
- 手动卡片按钮、菜单栏按钮、自动切换和命令行验收入口统一复用同一条身份、锁、原子写入、校验、回滚与恢复路径；当前账号按钮改为不可重复点击。
- 5 小时与 7 天暖号分别按自己的成功间隔节流；修复窗口状态未知时短间隔重复执行的问题。
- 官方账号累计与本机全 Agent 累计采用持久化高水位，切换账号或短暂缺失统计时不再倒退。
- Pro 账号可手动标记 `5x` 或 `20x`，只影响显示，不参与额度和切换判断。
- 重排账号卡和设置页信息层级，使用原生菜单、图标分区与 Next 品牌标识；新增不读取账号数据的可重复文档截图入口。

### English

- Automatic switching now triggers at `<= 5%` remaining for the 5-hour window or `< 10%` for the 7-day window; candidates still require at least `30%` in each triggered window.
- Added per-account automatic-switch participation while preserving 7-day and unexpected-reset warm-ups for excluded accounts.
- Unified manual, menu, automatic, and CLI switching through the existing verified transaction path and disabled the action for the current account.
- Added per-window warm-up throttling, monotonic lifetime totals, optional Pro `5x`/`20x` labels, refreshed account/settings layouts, and a privacy-safe documentation screenshot renderer.

## 8.24.1 / 0824v1 - 2026-08-24

- 新增默认关闭的低额度自动切换：官方 5 小时或 7 天窗口严格低于 10% 才评估；候选账号必须实时验证身份，并在全部触发窗口不少于 30%。
- 自动切换增加实时任务、Codex 前台空闲、旧版管理器、冷却和跨进程锁门禁；手动与自动流程统一使用优雅退出、原子写入、写后校验、失败恢复与重新打开。
- 新增默认关闭的飞书结果通知：Webhook 仅存 Keychain，只允许官方 HTTPS 主机与路径、禁止重定向，并只发送脱敏账号和额度事件。
- 新增有界本机自动化审计与原生 SwiftUI 自动化中心；Next 的 Bundle、可执行文件、账号目录、Application Support、缓存、偏好、快捷键和更新源均与旧版隔离。
- 智能暖号改为显式手动刷新后的单次计划；启动、唤醒和失败不再触发自动重试。
- 保留原 macOS/Windows 功能，并合并系统账号身份校验、CC Switch 读取、聚合去重和整数溢出保护。

### English

- Added opt-in automatic switching when an official 5-hour or 7-day window is strictly below 10%; candidates require realtime identity validation and at least 30% in every triggering window.
- Added live-task, foreground-idle, legacy-manager, cooldown, and cross-process lock gates. Manual and automatic switching now share graceful exit, atomic write, verification, recovery, and reopen behavior.
- Added opt-in Feishu result cards with Keychain-only webhook storage, official HTTPS host/path allowlisting, redirect rejection, and masked event data.
- Added bounded local automation audit history and a native SwiftUI automation center. Next isolates bundle, executable, profile, support, cache, defaults, shortcut, and update namespaces from the legacy app.
- Warm-up is now a one-shot plan after explicit manual refresh; startup, wake, and failures no longer auto-retry.
- Preserved the inherited macOS/Windows feature set and ported identity, CC Switch, aggregation de-duplication, and integer-overflow safety fixes.

## 0818v1 - 2026-08-18

- 账号额度按独立 `CODEX_HOME` 读取并校验身份，修复切换账号后菜单栏仍显示旧账号额度的问题。
- “切换并打开”保存当前登录后正常退出 Codex、调用官方注销、原子写入目标本地凭据并重新打开，避免运行中进程不刷新身份。
- 账号列表支持重新登录、独立登录、排序、备注和删除；主界面与菜单栏使用同一账号顺序。
- 所有剩余额度进度统一为健康度语义：55% 及以上蓝色、25–54% 黄色、低于 25% 红色。
- 重做菜单栏圆环和液态玻璃账号面板，修复设置弹窗闪退、错误锚定和液态键帽深色模式。
- 本地凭据不显示、不记录、不上传；发布仓库排除本机设计稿、构建产物和账号数据。

### English

- Isolated quota reads by `CODEX_HOME` with identity checks, fixing stale menu-bar quota after an account switch.
- “Switch & Open” now preserves the current login, gracefully quits Codex, performs official logout, atomically installs verified local credentials, and reopens Codex to avoid stale in-process identity.
- Added re-login, independent login, ordering, notes, and deletion for saved accounts, with consistent order across the main window and menu panel.
- Unified remaining-quota health colors: blue at 55% or above, yellow at 25–54%, and red below 25%.
- Reworked the menu-bar ring and Liquid Glass account panel; fixed transient settings dismissal, incorrect anchoring, and the Liquid Keycap dark appearance.
- Credentials stay local and are never displayed, logged, or uploaded; local design prototypes, build artifacts, and account data are excluded from publication.

## 1.3.0 - 2026-08-04

- 新增本机推理性能监测：从最近 28 天 Codex rollout 识别完整模型调用，按模型与推理强度展示平均耗时、P50、P90、有效吞吐和 reasoning token 占比，并支持今日、7 日均和 28 日均视图。
- 推理性能样本经过时间戳噪声过滤、有界去重和本地持久化；不保存或展示 prompt、回复、路径，也不把指标冒充 TTFT 或可见文本解码 TPS。
- 推理性能监测使用独立的历史存储和聚合路径，不改变现有额度、token、趋势与任务数据口径。
- 发布流程补齐 macOS 双架构 DMG 与 Windows x86_64 MSI/NSIS 安装包的 CI 构建、checksum 和跨平台资产校验。
- 保持本地优先和隐私边界：不新增遥测，不上传 usage、线程、路径、日志或账户数据。

## 1.2.1 - 2026-07-24

- 修复 AI 领导力尚未形成等级、但今日已有 Agent 记录时，指挥半径 Canvas 因零轨道参与节点布局而触发 `SIGTRAP` 连续崩溃的问题；零轨道状态现在会跳过节点绘制，并补充对应回归测试。
- Codex 用量趋势新增模型活动概览与按模型面积图，支持 30、60、90、180 天范围、Top 8 + 其他模型、token / API 等效估算费用切换和全局总量虚线。
- 模型费用缺少专属价格时明确标注使用 GPT-5.5 参考价格，优化图例、行样式和 tooltip 的信息层级；Claude Code 暂不支持模型归因时保留清晰降级说明。
- 继续保持本地优先：模型归因、领导力修复和趋势聚合均在本机完成，不新增遥测或用户数据上传。

## 1.2.0 - 2026-07-22

- 全网首推本地 AI 领导力评估模型：合并 Codex 与 Claude Code 的 Worker 证据，以滚动 28 天的管理半径、劳动力杠杆、编排能力和自主运行生成 0–100 分与七级中文称号。
- 主界面新增动态“等级徽章 + 指挥半径”第一视觉，展示 28 天领导 Agent、AI 工时和峰值并发；轨道节点按今日 Agent 数刷新、最多 12 个，并在窗口聚焦时公转与呼吸。
- 新增 AI 领导力详情 Tab：等级进度、四项核心指标、四维分值、每日 AI 工时/Agent/峰值组合趋势和项目贡献；个人得分始终合并全部 Runtime。
- AI 领导力只使用事实或可推导的本机结构证据，不让成本、交付和估算区间进入分数；缺失数据不伪造成 0。
- 七级称号更新为“碳基牛马、赛博监工、分身队长、硅基领主、硅基统帅、超级个体、人类最强者”，并配套高分辨率 PNG 徽章。
- 七级称号补齐正式英文映射；等级进度 Title 改用语义前景色，在浅色与深色模式下均保持可读。
- 修复 AI 领导力 SQLite 查询的无界进程输出读取：增加 32 MiB 总量上限、POSIX 分块读取、stderr 重定向和超限进程清理；AI 领导力与 Claude transcript 磁盘缓存补齐读写字节上限。
- 发布流程新增 GitHub Release 精简正文生成与校验，只公开版本摘要和主要更新，完整验证与 checksum 继续保留在仓库发布说明中。

## 1.1.5 - 2026-07-21

- 修复从已有 Codex 对话创建分支后，分支继承的 `token_count` 历史被再次计入累计、今日和近 7 日用量的问题。
- 通过父子线程元数据与 token 事件公共前缀识别继承历史，只保留分支创建后的新增用量；SQLite 回退、精细统计、趋势和项目排行统一使用去重口径。
- 分支事件身份使用紧凑指纹，并以有界两遍扫描替代全量 session entry 常驻；全局内存风险门禁新增对应阻断检查。

## 1.1.4 - 2026-07-17

- 修复 app-server 长连接 stdout 使用 Foundation 定长读取时等待凑满 64 KiB、导致初始化响应无法消费和 Codex 额度超时的问题；改用有背压的 POSIX 分块读取，并补充部分响应与 EOF 回归测试。
- 同步修复今日任务 app-server 长连接的读取语义，保留 1 MiB 缓冲上限、单请求并发、超时和进程清理边界。
- 全局内存风险门禁新增 app-server 部分响应检查，发布包装强制执行 pipe 部分读取与 EOF 自测。

## 1.1.3 - 2026-07-17

- 修复 macOS 13 上 Claude Skill 项目路径上溯越过文件系统根目录后持续生成 `/..` 链的问题，避免启动刷新长期占满 CPU 并导致常驻内存无限增长。
- 路径解析增加显式根目录终止和 visited 路径去重双重保护，并补充 macOS 13 Foundation 根目录父路径异常的回归测试。
- 全局内存风险门禁新增父路径上溯终止、循环去重与回归断言检查；发布包装强制运行 Claude Skill 路径自测。

## 1.1.2 - 2026-07-17

- 修复 macOS 13 上 app-server 长连接与一次性额度读取可能无界累积输出、悬挂请求和子进程的问题，增加缓冲区、并发、超时、EOF 与强制清理边界。
- Codex 与 Claude Code 会话解析改为流式读取并限制单行大小；进程输出、Skill 文件、内存/持久缓存和解析工作集增加容量上限与淘汰，降低大型本地数据集下的内存峰值。
- 发布流程新增全局内存泄露风险门禁，扫描生产 Swift 中的无界 FileHandle/Process/Pipe、Timer 生命周期、缓存及观察者清理风险；门禁未通过时禁止打包和发布。
- 新增冷/热缓存、大型本地 Codex 数据集和失效 app-server socket 的内存稳定性验证，不新增遥测或用户数据上传。

## 1.1.1 - 2026-07-16

- 今日任务看板改为来源感知的可信分类：Codex 使用“最近活跃、待继续、定时、今日归档”，Claude Code 保留显式运行、失败、阻塞、完成和未知状态；归档与近期活动不再被包装成成功或实时执行。
- 重排任务卡片信息层级，优先展示标题、工作区、事实时间和状态；支持整卡打开 Codex Session、hover/手型/键盘焦点反馈，并移除无行为图标与弱语义头像。
- Codex automation 支持常见 RRULE、时区和下次运行时间计算；规则不完整时只展示可验证周期，不再把配置更新时间当作运行时间。
- 新增 Codex Team 月额度窗口识别与菜单栏剩余额度表达，兼容月额度字段别名、单/月窗口拓扑和缺失数据降级。
- Claude Code Skill 路径可从个人、项目、嵌套、插件及旧版 command 目录回退定位，并补充静态 Token/字节估算和去重合并。
- 主窗口支持 820–1280pt 宽度调整并恢复上次尺寸；额度重置明细统一支持悬停查看。
- 新增隐私安全的本地性能采样、阶段验收门禁与项目级 Skill 统一目录，扩展任务、额度、性能、Claude Skill 路径和 macOS 兼容性自测。

## 1.1.0 - 2026-07-15

- 新增受控配色插件体系：内置默认、青花瓷、故宫红、千里江山、敦煌飞天和兰亭晨曦六套稳定配色，支持浅色/深色语义 token、受限 SVG 视觉资源、即时预览与切换。
- 新增独立 Liquid Glass 配色图库；社区配色采用仓库内审核投稿机制，提供贡献模板、严格文件白名单、来源与许可证元数据、生命周期控制以及 CI 渲染验证，不开放用户侧自由安装。
- Codex 返回可用额度重置次数时，展示总数和最早到期明细；完整过期列表可通过悬停查看，并在 JSON dump 中输出结构化详情。
- 将最低系统要求降至 macOS 13，同时通过条件编译保留新系统上的 Liquid Glass 能力，并补充双架构兼容性检查。
- 修复 Codex `token_count` 累计字段缺失、局部回退或计数器重置时重复计入整份累计值的问题；优先采用单次 `last_token_usage`（包括仅提供单次用量的事件），并在精细统计与 SQLite 线程统计出现极端倍率差异时安全回退。
- 统一设置页与配色图库的玻璃层级、字体、控件栅格和间距，并补充配色包、状态栏渲染、额度重置次数与 Token 归一化自测。

## 1.0.5 - 2026-07-14

- Codex 额度展示会按可信响应中的实际窗口数量自适应：仅有 7 天额度时使用单环、单进度条和居中百分比；双窗口恢复完整双环；服务明确返回零个额度限制时显示无限制状态。
- 对失败、畸形、未知、重复和部分额度响应采用 fail-closed 策略，保留最近一次可信布局并标记为陈旧数据，避免短暂异常误判为无限制或造成界面跳变。
- 恢复完整环形粒子效果并将粒子约束在进度环描边内；默认仅在主窗口可见、置前且聚焦时渲染，省电模式仅在悬停环形区域时渲染，同时响应低电量、温控和减少动态效果状态。
- 进一步收紧后台刷新条件和定时器容差：任务看板只在相关视图活跃时高频刷新，窗口失焦、最小化、被遮挡或位于其他 Space 时停止无效动画和刷新。
- 优化单额度菜单栏样式、重置倒计时与对比度：百分比居中显示，文字会根据已填充/未填充背景自动切换颜色，重置时间使用 `↻ 5d` 等紧凑语义并补齐 VoiceOver 描述。
- Claude Code transcript 缓存升级为纳秒级文件指纹，兼容迁移旧缓存、清理已删除文件记录并显式报告写入失败，减少不必要的重复解析。
- 扩展发布门禁，新增额度拓扑、状态栏像素布局、粒子生命周期、缓存迁移与热路径回归测试。

## 1.0.4 - 2026-07-13

- 修复 Codex 仅返回 7 天额度窗口时被误标为 5 小时额度的问题；额度窗口现在按 `windowDurationMins` 归一化，不再依赖 `primary` / `secondary` 槽位顺序，并覆盖单窗口、双窗口、顺序颠倒和未知窗口自测。
- 修复菜单栏状态项的外观监听与重绘反馈回环，避免空闲时持续占用单个 CPU 核心，并缓存 Runtime 模板图像以减少解码开销。
- 任务看板改为主窗口或状态弹窗可见时每 10 秒刷新、完全后台时每 60 秒刷新，并为周期任务增加系统可合并的定时器容差。
- 为 Codex session 用量内存缓存和持久缓存增加 1024 条容量限制，优先保留最近更新的会话，避免历史数据长期增长抬高内存基线。
- 全局快捷键支持在设置中自定义，并增加组合键校验、冲突检测与录制交互。

## 1.0.3 - 2026-07-11

- 新增跟随系统、UTC 日界线与固定 IANA 时区三种自然日统计模式，Codex、Claude Code、趋势、任务与 SQLite 回退统一使用同一时区口径。
- 为时区切换增加加载与成功反馈，并缓存最近使用的统计时区快照，频繁往返切换可即时完成。
- 菜单栏、Runtime 卡片和主窗口统一优先使用 session `token_count` 精细今日用量，仅在精细数据缺失时回退 SQLite 粗略统计。
- 修复刷新期间重复点击导致当前结果被丢弃、等待时间翻倍的问题；刷新中按钮会禁用并保留原有 hourglass 状态。
- 统一 K/M/B token 格式化，修复单位边界舍入，并补充时区、DST、格式化和回退口径自测。

## 1.0.2 - 2026-07-10

- 状态栏新增简约、经典、丰富三档展示模式，可独立选择已用量/剩余量口径、5 小时额度、7 天额度、今日 token 与重置倒计时。
- 简约模式使用无 Logo 的加粗蓝紫双环；经典模式使用纯数字额度环；丰富模式保留完整标签、进度条、百分比和重置时间。
- 状态栏背景改为透明，品牌 Logo 派生为系统单色模板，文字与图标按菜单栏实际深浅自动适配。
- 提高 5h/7d 标签和重置时间的对比度，今日总量改用系统菜单栏正文尺寸，并保持固定宽度与稳定布局。
- 设置窗口新增共享渲染器实时预览，所有显示配置即时保存并应用。

## 1.0.1 - 2026-07-10

- 兼容新版 ChatGPT/Codex App 的动态路径，同时保留旧版 App 与标准 CLI 回退。
- 双环额度新增低开销逆时针粒子流，只在剩余额度弧段内运动，并支持“减少动态效果”。
- 关闭主窗口且继续后台运行时，隐藏 Dock 图标并保留菜单栏状态项；从菜单栏或快捷键唤回主窗口时恢复标准窗口模式。

## 1.0.0-beta03 - 2026-07-09

- 新增 GitHub Release 更新检测：默认每天最多自动检查一次，并默认接收 beta/prerelease 版本；发现新版时在主窗口、菜单栏 Runtime 浮窗和设置系统区提示。
- 更新入口提供匹配当前 Mac 架构的 DMG 下载和 GitHub Release 页面跳转；不会静默下载或自动安装。
- 设置窗口将“更新”并入“系统”区，保留自动检查开关，并把手动检查、最新状态和操作按钮合并到一行。
- Runtime 展示配置改为单行多选 segmented 控件，Codex / Claude Code 带 logo，并继续确保至少保留一个 Runtime。
- 新增版本比较、GitHub Release 元数据解析、ETag/24 小时缓存和 `--self-test-updates` 自测入口。

## 1.0.0-beta02 - 2026-07-08

- 新增 Runtime 展示设置：默认展示 Codex 和 Claude Code，可在设置中选择要显示的 Runtime，并确保至少保留一个。
- 用量趋势中的近 7 日折线图和最近半年热力图新增应用内 hover 详情浮窗，展示日期、Runtime、token 总量、可用拆分和统计口径；近 7 日折线图支持整图横向 hover 切换日期，不再要求精确悬停圆点。
- 设置页 checkbox 统一改为 switch 开关，语言/外观分段控件圆角与设计标准对齐，所有设置操作控件右对齐。
- 主窗口标题栏 Runtime 与操作按钮组右对齐，并增加顶部间距，避免贴近窗口边框。
- 将主界面升级为标准 macOS App 窗口，支持 Dock、系统红黄绿窗口控制、最小化，以及关闭主窗口后继续在菜单栏运行。
- 保留菜单栏状态项，并增强 Runtime 浮窗：新增设置入口，支持打开主窗口、打开设置和退出。
- `Command + U` 调整为显示/隐藏主窗口；窗口最小化时会恢复并唤到前台。
- 菜单栏浮窗支持在其他全屏 App 的当前 Space 中展示。
- 新增设置窗口，集中管理语言、外观、主窗口置顶和关闭行为；语言、主题和 PRO 状态不再常驻主窗口顶部。
- 恢复主窗口 Liquid Glass 材质和半透明质感，并优化标题栏工具区、窗口圆角、顶部间距和按钮尺寸。
- 新增 Codex 与 Claude Code 彩色 Runtime 图标资源，统一主窗口、菜单栏浮窗和 Runtime 切换控件的视觉。
- 更新 README 截图、安装说明和源码构建示例。

## 0.4.0 - 2026-07-07

- Added a multi-runtime usage architecture with Codex and Claude Code providers.
- Added Claude Code local transcript parsing for tokens, trends, projects, tool usage, Skill usage, and tasks.
- Added a menu bar runtime popover with Codex and Claude Code summary cards and total tokens today.
- Added a top-level Codex / Claude Code switch in the main widget.
- Added runtime-aware `--dump-json` output with `schemaVersion: 2`, `aggregate`, `runtimes[]`, and legacy Codex compatibility fields.
- Added local statusLine snapshot support for Claude Code active quota, with missing/stale diagnostics.

## 0.3.0 - 2026-07-04

- Reworked the lower dashboard into three tabs: today's task board, usage trend, and project board.
- Added a six-month daily token heatmap with local `token_count` event aggregation, fixed week-by-week matrix layout, percentile-based purple intensity levels, and per-day hover tooltips.
- Added a last-7-day line chart with total, daily average, and previous-period comparison.
- Added project usage rankings for the last 7 days and all time, with thread counts, recent activity, and detailed/approximate source labels.
- Added tool usage TOP10 with call counts, categories, and session-share token/value estimates.
- Added Skill usage TOP20 analytics based on local Skill load events.
- Added local analytics JSON output for trend, project, and tool data in `--dump-json`.
- Added foreground pin mode while keeping `Command + U` as a temporary foreground toggle.
- Fixed heatmap month labels so each month starts on the week column containing that month's first day.
- Documented the historical v0.3.0 product requirements; that superseded document remains available in Git history.

## 0.2.0 - 2026-07-01

- Introduced the new Apple-inspired visual system with refined light and dark palettes, elevated surfaces, consistent control styling, and updated token colors.
- Added system, light, and dark appearance modes with a persistent top-level mode switch.
- Added detailed token parsing from local Codex `token_count` session events, including uncached input, cached input, output, and monthly API-equivalent value estimates.
- Redesigned the value progress card around Plus, Pro100, Pro200, and full monthly quota milestones.
- Simplified the quota area by moving reset times under the dual ring and removing redundant 5-hour and 7-day progress rows.
- Increased the widget height so task board rows have more room to render cleanly.
- Added explicit Intel Mac and Apple Silicon DMG packaging targets and documented x86_64 release artifacts.

## 0.1.4

- Added Chinese and English UI text support.
- Default language now follows the system time zone: Chinese for China/Hong Kong/Macau/Taiwan time zones, English otherwise.
- Added a top bar `中 | EN` language switch that persists the manual selection.

## 0.1.3

- Added the app icon to the widget header.
- Moved account status into a right-side pill next to the plan badge.
- Updated the README screenshot for the new header layout.

## 0.1.2

- Added local desktop widget UI for Codex quota, token usage, trend, and task board.
- Added `Command + U` foreground/desktop layer toggle.
- Added DMG packaging, checksum generation, signing hooks, and notarization helper.
- Added local data source probe command.
