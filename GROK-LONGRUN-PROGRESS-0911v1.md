# AiGoodBro UI 长线进度 · 0911v1

工作区：`camnext-0911v14-candidate`。最终验收见 `GROK-UI-ACCEPTANCE-0911v2.md`。

## 总表

| ID | 状态 | 备注 |
|---|---|---|
| 品牌图标 | 完成（合成预览已看） | C2 AH 连字；验收板已生成 |
| T01 Token 汇总 | 完成 | `TokenTotalsHeader` 三处复用；去掉 Codex 页 `minHeight: 188` |
| T02 重置消息条 | 完成 | `ResetUpdatesBanner`；窗口/公告/重置卡分列 |
| T03 不可执行原因 | 完成 | `HubCLIBlockDetail` + `blockingReason`；未改 `blocksLocalCLI` |
| T04 任务状态文案 | 完成 | `TaskStatusCopy` |
| T05 工作台信息架构 | 完成 | 总量卡 / 重置条 / 监控卡拆开；单账号「当前可执行」 |
| T06 模型可用性摘要 | 完成 | 卡片「可用模型 N · 已验证 M」或「暂无验证记录」 |
| T07 菜单栏导航与品牌 | 完成 | 横条标签、五项底栏、退出 AiGoodBro；单账号菜单补总量并可滚 |
| T08 设置页规范化 | 完成 | 12.5/10.5、spacing 6、ErrorRow 对齐、暖号走 BaseRow |
| T09 执行档位双行 | 完成 | 预设按钮增加行为摘要 |
| T10 大文件拆分 | 跳过 | 见下 |
| T11 颜色语义 | 部分完成 | 状态色已收；表面 `Color.primary.opacity` 未全收 |
| T12 非 Codex 模型调研 | 完成 | `docs/non-codex-model-selection-0911v1.md` |

## T10 跳过理由

`CodexAccountManagerView.swift` 仍约 5700 行。`CodexAccountMenuView`、`AccountAutomationCenterView`、`ProfileRow` 依赖同文件的 `AccountGlassButtonStyle`、`QuotaDetailTile`、`HubCLITaskStatusBadge`、`AccountCardFooterSlots` 等。提升访问级别后 diff 无法表现为纯移动，且无法做像素级无差异对比。按授权记录后继续 T11/T12。

## 续做（验收残留）

- 菜单额度砖「窗口重置」去掉相对时间括号，380 宽不再出现 `2...`
- 设置关于页：开源声明移到品牌名下；compact 可滚；更新检查行在英文首屏可见
- 英文单数：「1 account has reset cards」
- 补专业版 Codex 工作台合成预览；Codex 页顺序改为总量 → 重置条 → 当前可执行

## 最终验证

- `make build BUILD_DIR=.local-artifacts/grok-ui-p11-build SWIFT_OPTIMIZATION=-Onone` 成功
- `scripts/run-self-tests.sh --skip-build --build-dir .local-artifacts/grok-ui-p11-build`：**29/29 通过**
- `git diff --check` 干净
- 工作台预览：`.local-artifacts/grok-ui-p11-previews-zh/`（含 `professional-codex-*`）；英文 `.local-artifacts/grok-ui-p10-previews-en/`
- 设置预览：`.local-artifacts/grok-ui-p10-settings/`
- 品牌板：`docs/images/ah-brand-0911v1/ah-brand-acceptance-board.png`

## 未真实验证

真实窗口点击、菜单栏弹出位置、VoiceOver、banner 打开自动化中心、设置热区。本轮未安装、未覆盖运行中应用。
