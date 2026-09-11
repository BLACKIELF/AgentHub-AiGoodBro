# AiGoodBro 图标重做 brief · 0911v2

用户原话：当前图标不好看。让 Kimi **先了解项目背景再做**。突出 **AiGoodBro** 和 **工作台 reset 通知**。不要再画一个没有产品故事的字母积木。

你的唯一可写工作区：

`/Users/lovelifeblackie/Documents/AgentHub/10-projects/2026/Swift/work/camnext-0911v13-kimi-icon`

不要写其它 worktree。不要 commit / push / install。不要改额度、认证、调度、通知、持久化、`~/.codex`、Windows。

## 这是什么产品（先读完再画）

**AiGoodBro** 是 macOS 菜单栏 + 主窗口应用。对外软件名 AiGoodBro，短名 **AH**，主窗口工作台名 **AgentHub**。

它不是聊天机器人，也不是又一个「AI 字母标」。用户拿它做三件事：

1. **看清额度**：官方 5 小时窗口、7 天窗口、本机 Agent token、未知值绝不能写成 0。
2. **盯重置**：窗口重置时间、公开重置公告、可用重置卡，三层必须分开。这是本产品最独特的工作台信息，用户明确要求图标和工作台都要能让人感到「这里管 reset」。
3. **安全地开下一次任务**：多账号、暖号、占用、Hub 阻塞原因。忙碌或状态不可信时不能假装空闲。

竞品错觉要避开：不要机器人头、不要 ChatGPT / Claude / Grok / Codex 商标、不要通用六边形芯片、不要把「AH」两字小字塞进图标。

当前 C2（蓝圆角方块 + AH 连字 + 横杠实心圆点）已被用户否决。否决原因：

- 看起来像随便一个 AH 字母标，认不出 AiGoodBro。
- 横杠上的实心圆像脏点/渲染错误，不像「中枢」，更不像「重置窗口」。
- 完全没有工作台、额度窗口、reset 周期的感觉。
- 16px 还能认字母，但没有产品记忆点。

## 设计必须同时读出的三件事

1. **AiGoodBro**：友好、可靠的协作中枢，不是冷冰冰的企业徽章。AH 可以是母题，但必须是一个符号，不是贴字。
2. **工作台 AgentHub**：命令中心 / 汇聚多 Agent 的台面。可用中枢、轨道、窗口框架，但 16px 不能碎。
3. **Reset 通知**：5h / 7d 窗口会转回来。循环、缺口圆环、回转箭头都可以，但不要时钟指针、不要日历格子、不要感叹号角标（那会像系统通知垃圾）。

浅色/深色、彩色底板/模板单色都要成套。macOS squircle 安全区。透明边缘。避免细线、微字、复杂光效。

## 你要做的

1. 先在 `docs/images/ah-brand-0911v1/candidates/` 产出 **至少 3 个新产品向候选**（不要再交 C1/C2/C3 微调）。每个候选：256px、64/32/16 条、深底各一张。
2. 自己对抗审查：16px 是否可辨、reset 语义会不会被看成脏点、会不会像第三方商标。选一个实施。
3. 用可复现脚本更新 `scripts/generate-ah-brand-icons.py`，`--final` 写 `Resources/codexU-icon.png` 与 `Resources/codexU.icns`。`AHBrandSymbol`（`Sources/CodexUsageWidget/UI/AHBrandPresentation.swift`）必须与脚本几何同源。
4. 重画验收板 `docs/images/ah-brand-0911v1/ah-brand-acceptance-board.png`。
5. 把选择理由写入 `KIMI-ICON-DESIGN-0911v1.md`（可覆盖旧 C2 结论，写明 C2 为何被否）。

验收：`git diff --check`；不要为了图标去改 self-test 口径，除非尺寸/alpha 断言必须跟着新资源走。做完在工作区根写下 `KIMI-ICON-RESULT-0911v2.md`，列出改动文件、入选/淘汰、复现命令。

父执行端会在 `camnext-0911v14-candidate` 做工作台 reset 条、对抗审查、覆盖安装和 GitHub 推送。你只负责图标与品牌标记。
