# AiGoodBro UI 长线进度 · 0911v1

工作区：`camnext-0911v14-candidate`。最终验收见 `GROK-UI-ACCEPTANCE-0911v2.md`。

## 总表

| ID | 状态 | 备注 |
|---|---|---|
| 品牌图标 | 完成（合成预览已看） | C5：工作台内框 + 重置圆环；C2 已否 |
| T01 Token 汇总 | 完成 | `TokenTotalsHeader` 三处复用；去掉**总量卡** `minHeight: 188`；API 等效只显示 ≈$ 不再用 6.8 换算人民币 |
| T02 重置消息条 | 完成 | `ResetUpdatesBanner`；窗口/公告/重置卡分列 |
| T03 不可执行原因 | 完成 | `HubCLIBlockDetail` + `blockingReason`；未改 `blocksLocalCLI` |
| T04 任务状态文案 | 完成 | `TaskStatusCopy` |
| T05 工作台信息架构 | 完成 | 总量卡 / 重置条 / 监控卡拆开；单账号「当前可执行」 |
| T06 模型可用性摘要 | 完成 | 卡片「可用模型 N · 已验证 M」或「暂无验证记录」 |
| T07 菜单栏导航与品牌 | 完成 | 横条标签、五项底栏、退出 AiGoodBro；单账号菜单补总量并可滚 |
| T08 设置页规范化 | 完成 | 12.5/10.5、spacing 6、ErrorRow 对齐、暖号走 BaseRow |
| T09 执行档位双行 | 完成 | 预设按钮增加行为摘要 |
| T10 大文件拆分 | 跳过 | 见下 |
| T11 颜色语义 | 完成 | 状态色走 `status*`；UI 表面散写收进 `FixedVisualPalette.surface*`，原 token 数值未改 |
| T12 非 Codex 模型调研 | 完成 | `docs/non-codex-model-selection-0911v1.md` |

## T10 跳过理由

`CodexAccountManagerView.swift` 仍约 5700 行。`CodexAccountMenuView`、`AccountAutomationCenterView`、`ProfileRow` 依赖同文件的 `AccountGlassButtonStyle`、`QuotaDetailTile`、`HubCLITaskStatusBadge`、`AccountCardFooterSlots` 等。提升访问级别后 diff 无法表现为纯移动，且无法做像素级无差异对比。按授权记录后继续 T11/T12。

## 续做（本轮已收）

- 菜单额度砖「窗口重置」去掉相对时间括号；英文改为 `Resets Sep 11 23:31` 单行
- 设置关于页：开源声明在品牌名下；英文「Daily GitHub Releases check, including beta」；Update check 明细首屏可见
- 英文单数：「1 account has reset cards」
- Codex 页：总量 → 重置条 → 当前可执行；标题改为突出 AiGoodBro，副标题带重置窗口
- 重置条加「重置消息」标题与左侧强调条
- `blockingReason` 在缺少 `blockDetail` 时不再猜成 Hub 离线

## 最终验证

- `make build BUILD_DIR=.local-artifacts/grok-ui-p14-build SWIFT_OPTIMIZATION=-Onone` 成功
- `scripts/run-self-tests.sh --skip-build --build-dir .local-artifacts/grok-ui-p14-build`：**29/29 通过**
- 对抗审查 `review-outputs/grok-adversarial-0911v3.md`：重置卡计数未知≠0 已修；loading 不再写成 Hub 离线
- `git diff --check` 干净
- 工作台预览：`.local-artifacts/grok-ui-p12-previews-zh/` 与 `...-en/`（各 76）；设置 `.local-artifacts/grok-ui-p12-settings/`（24）
- 品牌板：`docs/images/ah-brand-0911v1/ah-brand-acceptance-board.png`（C5）

## 未真实验证

真实窗口点击、菜单栏弹出位置、VoiceOver、banner 打开自动化中心、设置热区。本轮未安装、未覆盖运行中应用。

## Codex 已接管（改动通知）

Codex 按 `GROK-UI-ACCEPTANCE-0911v2.md` 第 8 节完成复验，并**改动了一个本轮新增文件**：
`Sources/CodexUsageWidget/Domain/AHBrandAssetsSelfTest.swift`——补上了原本只写在注释里、实际没有校验的 `.icns` 与 MIT 归属两项。

改动详情、原因与「未改动但请回看」的两条（硬编码汇率、`minHeight: 188` 措辞）见
`GROK-UI-ACCEPTANCE-0911v2.md` 第 9 节 与 `CODEX-UI-REVIEW-0911v2.md`。

复验结果：格式通过、隔离构建成功、签名通过、**29/29 自测通过**。
已推送 `origin/codex/aigoodbro-ui-0911v2`（`48de939` / `724a169`）。本工作区还有 C5 图标、重置条强调、T11 表面色、汇率与 blockingReason 续做，待叠到该分支。

WorkBuddy GUI 在同 worktree 做 Windows 切片 S1–S6，已推 `origin/codex/windows-agenthub-0911v1`（tip `54a1e7b`）。它改过 `AHBrandAssetsSelfTest.swift`（补 icns/MIT 真校验）——与当前工作树一致，保留。Windows 文件不纳入本轮 UI 提交。
