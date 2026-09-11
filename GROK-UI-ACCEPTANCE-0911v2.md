# AiGoodBro UI 验收 · 0911v2

相较 v1（品牌图标 + T01 Token 汇总抽取），本轮把规划 T02–T09、T11 状态色、T12 调研做完，并修了菜单栏单账号首页被总量卡撑出底栏的问题。T10 大文件拆分已跳过。Codex 可按本文件复验，不要把编译通过当成真实点击验收。

工作区：`camnext-0911v14-candidate`。未 commit、未 push、未安装、未覆盖运行中应用。Windows 目录里另有其他执行者改动，本轮未改、未还原。

## 1. v1 范围回顾

- 应用图标与 `AHBrandSymbol` 换成 C2 AH 枢纽连字；第三方 Codex/Claude 图标未动。
- `TokenTotalsHeader` 统一主页 / Codex 页 / 菜单「总 Token 消耗量」，官方 / 本机 / API 等效分行；未知仍显示「暂无记录」，不写成 0。
- Codex 工作台总量已移出折叠区。

v1 未写独立验收文件，以上并入本文件。

## 2. v2 新增成果

| 任务 | 做了什么 |
|---|---|
| 品牌补齐 | 生成验收板与三候选预览；不重跑 `--final` |
| T01 缺陷 | 去掉总量卡旧双栏 `minHeight: 188` |
| T02 | 主页与 Codex 页增加只读 `ResetUpdatesBanner`；「窗口重置 / 公开重置公告 / 可用重置卡 / 本地重置记录」；Grok 外链改为「在官网查看重置卡」 |
| T03 | `HubCLIBlockDetail` + `blockingReason`；help 与执行说明改用分解原因；**未改** `blocksLocalCLI` |
| T04 | `TaskStatusCopy`：待你处理 / 待继续 / 待批准 / 受阻，断开与未知保留「回原任务核对」 |
| T05 | 总量卡、重置条、监控卡拆开；单账号 Codex「当前可执行」；Codex 页顺序为总量 → 重置条 → 当前可执行；补专业版 Codex 合成预览 |
| T06 | 本地 CLI 卡摘要行，点击展开既有模型清单 |
| T07 | 菜单横条三项标签；底栏五项分段；「退出 AiGoodBro」；单账号菜单补 compact 总量并可滚；额度砖窗口重置不再截断 |
| T08 | 设置行标题 12.5、说明 10.5；五页 spacing 6；ErrorRow 对齐；暖号改 BaseRow；关于页声明上移且 compact 可滚 |
| T09 | 狂蹬/中蹬/慢蹬按钮增加既有口径的行为摘要 |
| T10 | **跳过**：同文件私有助手过多，无法纯移动且无法像素对比 |
| T11 | 任务状态与到期/警示色改走 `FixedVisualPalette.status*`；表面透明度收到 `surface*`，原 token 数值未改 |
| T12 | `docs/non-codex-model-selection-0911v1.md`：非 Codex 不做 GUI 模型选择器 |

## 3. 修改文件清单（本轮 UI）

**改：**

- `Sources/CodexUsageWidget/UI/AHBrandPresentation.swift`
- `Sources/CodexUsageWidget/UI/CodexAccountManagerView.swift`
- `Sources/CodexUsageWidget/UI/ExecutionPreferenceControl.swift`
- `Sources/CodexUsageWidget/UI/LocalCLIModelAvailabilityView.swift`
- `Sources/CodexUsageWidget/UI/LocalCLIWorkspaceView.swift`
- `Sources/CodexUsageWidget/UI/SettingsPanelView.swift`
- `Sources/CodexUsageWidget/UI/StatusItemSettingsView.swift`
- `Sources/CodexUsageWidget/UI/TaskOverviewPanelView.swift`
- `Sources/CodexUsageWidget/UI/TokenTotalsHeader.swift`（v1 已有，本轮未再改几何）
- `Sources/CodexUsageWidget/Services/HubConsoleModel.swift`
- `Sources/CodexUsageWidget/Services/PublicResetAnnouncements.swift`（仅 preview `seedPreviewLatest`）
- `Sources/CodexUsageWidget/Services/CodexProfileStore.swift`（七天文案）
- `Sources/CodexUsageWidget/Domain/AccountTaskStatusSelfTest.swift`
- `Sources/CodexUsageWidget/Domain/LocalCLIModelAvailability.swift`
- `Sources/CodexUsageWidget/Domain/WorkspacePreviewRenderer.swift`
- `Sources/CodexUsageWidget/Domain/WorkspaceScreenshotSelfTest.swift`
- `Sources/CodexUsageWidget/main.swift`
- `Resources/codexU-icon.png` / `Resources/codexU.icns`
- `scripts/run-self-tests.sh` / `scripts/self-tests.txt`（v1 品牌自测入口）

**新：**

- `Sources/CodexUsageWidget/UI/ResetUpdatesBanner.swift`
- `Sources/CodexUsageWidget/Domain/TaskStatusCopy.swift`
- `Sources/CodexUsageWidget/Domain/AHBrandAssetsSelfTest.swift`
- `Sources/CodexUsageWidget/UI/TokenTotalsHeader.swift`
- `scripts/generate-ah-brand-icons.py`
- `docs/non-codex-model-selection-0911v1.md`
- `docs/images/ah-brand-0911v1/`
- `GROK-LONGRUN-PROGRESS-0911v1.md`
- 本文件

接手前已有 DISPATCH/KIMI 文档与 `review-outputs/0911v11/` 未动。Windows 工作区另有未提交改动，不属于本轮 UI。

## 4. 验证命令与结果

隔离构建（不碰运行中的 `build/`）：

```bash
make build BUILD_DIR=.local-artifacts/grok-ui-p12-build SWIFT_OPTIMIZATION=-Onone
# 成功；codesign --verify --deep --strict 通过
```

```bash
xcrun swift-format lint --strict --parallel --recursive --configuration .swift-format Sources/CodexUsageWidget
git diff --check
# 均干净
```

```bash
./scripts/run-self-tests.sh --skip-build --build-dir .local-artifacts/grok-ui-p12-build
# All 29 selected self-test(s) passed
```

合成预览（直接调隔离二进制，未再 `make build`）：

```bash
AiGoodBro --render-workspace-previews .local-artifacts/grok-ui-p11-previews-zh
AiGoodBro --render-workspace-previews .local-artifacts/grok-ui-p10-previews-en --preview-english
AiGoodBro --render-settings-previews .local-artifacts/grok-ui-p10-settings
```

中英工作台各 68 张，设置目录 24 张。已目视：浅/深、820 窄窗、有/无公告 banner、rows/cards、Grok 卡、档位编辑器、菜单五项底栏。

## 5. 截图索引

| 用途 | 路径 |
|---|---|
| 品牌验收板 | `docs/images/ah-brand-0911v1/ah-brand-acceptance-board.png` |
| 总量 + 重置条 + 监控卡（浅） | `.local-artifacts/grok-ui-p11-previews-zh/multi-account-light-980.png` |
| 820 窄窗深色 | `.local-artifacts/grok-ui-p11-previews-zh/single-account-dark-820.png` |
| Codex 页：总量 → 重置 → 当前可执行 | `.local-artifacts/grok-ui-p11-previews-zh/professional-codex-single-light-980.png` |
| 有合成公告 | `.local-artifacts/grok-ui-p11-previews-zh/reset-banner-announced-light.png` |
| 菜单栏（窗口重置完整 + 底栏） | `.local-artifacts/grok-ui-p11-previews-zh/single-account-menu-light.png` |
| 档位行为摘要 | `.local-artifacts/grok-ui-p11-previews-zh/astra-model-dark.png` |
| Grok 摘要 + 官网重置卡 | `.local-artifacts/grok-ui-p11-previews-zh/acceptance-provider-grok-light-760x640.png` |
| 设置暖号行 | `.local-artifacts/grok-ui-p10-settings/settings-automation-zh-light@2x.png` |
| 关于（声明在品牌名下） | `.local-artifacts/grok-ui-p10-settings/settings-about-zh-dark@2x.png` |
| 英文工作台 | `.local-artifacts/grok-ui-p10-previews-en/` |

## 6. 目视结论与残留

- 品牌 16–512px 可辨；菜单栏额度图标未改成品牌标（正确）。
- 总量 82.4M / 2.5 亿在 820 未截断；本机无记录显示「暂无记录」。
- 重置三层分开；有公告时标题可见。
- 不可执行说明已是「缺少可信账号映射…」而不是三合一句子。
- 菜单 380 宽「窗口重置」已改为只显示绝对时间，相对时间放在 help。
- 关于页开源声明已移到品牌名下方，首屏可读；更新检查一行在 550 高菜单里仍可能被底栏挡住，可上滚。
- UI 表面 `Color.primary.opacity` 已收到 `FixedVisualPalette.surface*`；既有 token 数值未改。
- 工作台标题改为 AiGoodBro 主名 + AgentHub/重置窗口副标题；有重置卡或公告时重置条带信息色强调。
- API 等效估算只保留 ≈$，不再用硬编码 6.8 换算人民币。

## 7. 未真实验证（必须标出）

- 真实主窗口 / 菜单栏弹出、pin、collapse
- banner 点击打开自动化中心并落到「重置消息」
- 各 Hub phase 的 help 悬停与 VoiceOver
- 设置新字号下的真实点击热区
- 档位 popover 真实高度
- 任务概览浮窗真实弹出（现无独立 fixture）

未执行登录、切号、重置卡兑换、通知、真实 CLI 启动。

## 8. Codex 接管步骤

1. 读本文件与 `GROK-LONGRUN-PROGRESS-0911v1.md`。
2. 精确暂存 **macOS UI 相关文件**；不要把 Windows 未提交改动算进本轮 UI。
3. 隐私扫描：预览均为 `example.invalid` 合成数据。
4. 用独立 `BUILD_DIR` 复跑 `swift-format`、`make build`、`run-self-tests.sh`、`git diff --check`。
5. 打开上表 PNG，不要只认文件存在。
6. 真实 GUI 回归需用户授权安装/启动；本轮禁止覆盖正在运行的应用。
7. 需要拆 CAMV 时另开任务，不要在本 diff 上硬拆。

## 9. Codex 改动通知（务必回看）

Codex 已按第 8 节接管并复验。**改动了一个本轮新增的文件**，在此登记，避免后续按旧内容继续工作：

**改：`Sources/CodexUsageWidget/Domain/AHBrandAssetsSelfTest.swift`**

原因：该自测的文档注释声称校验「the codexU MIT attribution required by the license」，但代码实际只校验身份常量与运行时 PNG，既没有校验任何归属文本，也没有校验 Finder/Dock 真正使用的 `.icns`。前者是注释不实，后者是覆盖缺口。

改动内容（三处，均为增补，未删除任何既有断言）：

1. 文档注释改为准确描述实际校验范围。
2. 新增 `.icns` 校验：打包内 `AiGoodBro.icns` 必须存在、可解码、且保留 ≥512px 表示。注意 `Makefile` 在打包时把 `Resources/codexU.icns` 重命名为 `AiGoodBro.icns`，两者是同一资源。
3. 新增 MIT 归属校验：打包内 `THIRD_PARTY_NOTICES.txt` 必须含 `shanggqm/codexU` 与 `MIT License`。

改动后已重跑格式检查（通过）、隔离构建（成功）、`run-self-tests.sh`（**29/29 通过**）。`EXPECTED_COUNT` 与清单条目数未变，无需调整。

**未改动、但请你回看的两条：**

- `TokenTotalsHeader` 已去掉人民币 6.8 换算，只保留 ≈$。
- 本文件第 2 节与进度文件的「去掉 `minHeight: 188`」措辞会让人以为该文件里再无该值；实际 `CodexAccountManagerView.swift:1624` 仍有（另一张 5h/7d 双栏卡，布局仍是双栏，合理）。建议措辞改为「去掉**总量卡**的 `minHeight: 188`」。

其余当时内容 Codex **一字未改**。独立复验记录见 `CODEX-UI-REVIEW-0911v2.md`；macOS UI 当时已推送到 `origin/codex/aigoodbro-ui-0911v2`（`48de939`，通知提交 `724a169`），与 Windows 移植分开分支。

后续 Grok 已按「未改动但请回看」处理：去掉人民币 6.8 换算；进度/验收措辞改为「去掉总量卡的 minHeight: 188」。`AHBrandAssetsSelfTest.swift` 与 Codex 补丁保持一致（未再改）。
