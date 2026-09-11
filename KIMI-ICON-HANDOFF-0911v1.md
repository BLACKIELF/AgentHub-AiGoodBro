# AiGoodBro 图标重设计与全局替换 · 0911v1

用户明确要求：图标重新设计，由 Kimi 直接执行，并在 AiGoodBro 内全局替换。

你现在是设计兼实现者。请先审查现有品牌标记与资源，再直接完成最小而完整的全局替换。不得只写方案。不得修改账号、额度、调度、网络、重置卡、用户配置或 Git 历史；不得提交、推送、安装、发布。

## 品牌目标

- 产品名：AiGoodBro；工作台名：AgentHub；短标识仍为 AH。
- 新图标要像“可靠的 AI 协作中枢”：清晰、克制、现代、原生 macOS 感，不做通用渐变机器人头、不照搬 Codex/OpenAI/Grok/Claude 等第三方商标。
- 核心母题建议：由 `A` 与 `H` 构成一个可识别的连接/中枢符号，兼顾“伙伴”与“多 Agent 汇聚”；你可在审查后提出更好的单一方向，但必须自洽。
- 需要在 16px 菜单栏、20–28px 界面品牌标记、64px 设置页、1024px App 图标上都可辨识。浅色/深色、彩色/模板单色需成体系。
- 避免细线、微小文字、过多节点、复杂光效；不得把“AH”两字直接小字号塞进图标。

## 全局替换范围

先全文核对实际引用，再处理这些现有入口：

- `Resources/codexU.icns`：应用打包图标；
- `Resources/codexU-icon.png`：1024×1024 运行时/展示资源；
- 与 AiGoodBro 品牌直接相关的彩色和模板资源；不要覆盖第三方 Provider 的 Codex 图标，除非确认该文件实际承担的是 AiGoodBro 品牌入口；
- `Sources/CodexUsageWidget/UI/AHBrandPresentation.swift` 中的 `AHBrandSymbol`；
- `Sources/CodexUsageWidget/UI/CodexAccountManagerView.swift`、`SettingsPanelView.swift` 等仍使用旧 `ZYZHMark` 的 AiGoodBro 品牌位置；
- 菜单栏/状态栏中的 AiGoodBro 自有标记与预览；不得把额度状态、Provider 图标或系统 SF Symbols 无差别替换。

“全局替换”指所有 AiGoodBro 自有品牌入口使用同一套新视觉语言，不是替换第三方服务图标。

## 实施约束

1. 优先用可复现的矢量/SwiftUI 形状作为源：新增一个清晰命名的源文件或生成脚本，并从它导出 PNG/ICNS；不要只留下不可编辑的二进制。
2. 只修改图标和品牌标记必需文件。现有工作树起点为提交 `489afe1`，与 Token UI 任务隔离。
3. 先生成 2–3 个小型候选预览图（同一母题的克制变体），自行对抗式审查后选一个实施；把选择理由、淘汰理由写入 `KIMI-ICON-DESIGN-0911v1.md`。
4. 保证透明边缘、macOS 图标安全区、模板图单色渲染、Retina 尺寸与 ICNS 内容有效。检查资源尺寸、alpha、hash。
5. 更新或新增最小 self-test/预览 fixture，仅用于验证品牌入口一致；不要顺手改其他 UI。

## 验收与交付

- 运行 `git diff --check`、Swift 格式检查、现有 build/self-test；若沙箱内无输出 134，保留产物并明确交给根中枢宿主复验，不因 seatbelt 单独回滚。
- 输出一张品牌验收板 PNG：至少包含 1024 App 图标、128/64/32/16 缩放、浅/深背景、彩色与模板版。
- 最终回执列出：修改文件、候选与最终选择、生成命令、尺寸/alpha/ICNS 检查、build/self-test、预览路径、未验证项。
- 只在本 worktree 写入；不修改 `KIMI-ICON-HANDOFF-0911v1.md`。
