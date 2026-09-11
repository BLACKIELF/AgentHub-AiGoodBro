# AiGoodBro UI 复验 · Codex 接管 · 0911v2

对 `GROK-UI-ACCEPTANCE-0911v2.md` 与 `GROK-LONGRUN-PROGRESS-0911v1.md` 所述 macOS UI 改动的独立复验。

工作区：`camnext-0911v14-candidate`。本轮**未安装、未启动、未覆盖运行中应用**，未执行登录 / 切号 / 重置卡兑换 / 通知发送 / 真实 CLI 启动。

## 1. 复验命令与结果

隔离构建目录 `.local-artifacts/codex-review-build`（不复用 grok 的 `grok-ui-p9-build`，不写运行中的 `build/`）：

| 命令 | 结果 |
|---|---|
| `xcrun swift-format lint --strict --parallel --recursive --configuration .swift-format Sources/CodexUsageWidget` | 通过 |
| `git diff --check` | 干净 |
| `make build BUILD_DIR=.local-artifacts/codex-review-build SWIFT_OPTIMIZATION=-Onone` | 成功 |
| `codesign --verify --deep --strict .local-artifacts/codex-review-build/AiGoodBro.app` | 通过 |
| `./scripts/run-self-tests.sh --skip-build --build-dir .local-artifacts/codex-review-build` | **29/29 通过** |
| 清单一致性 | `scripts/self-tests.txt` 29 项 == `EXPECTED_COUNT=29` |

## 2. 关键声明逐条核对

| 声明 | 结论 |
|---|---|
| `blockingReason` 是 presentation-only，不改 `blocksLocalCLI` | **成立**。diff 中 `blocksLocalCLI` 只被读取；其定义（`HubConsoleModel.swift:154`）未出现在任何 `+`/`-` 行 |
| T01 去掉了 Codex 页旧双栏 `minHeight: 188` | **成立，但措辞会误导**（见发现 B） |
| 品牌自测覆盖 MIT 归属 | **原为不实**（见发现 C），本轮已补成真校验 |
| 预览均为 `example.invalid` 合成数据 | **成立**。`WorkspacePreviewRenderer` 使用 `g***@example.invalid` 等；diff 与新文件隐私扫描无邮箱 / 私钥 / webhook / 绝对路径 |
| 新增自测已接线 | **成立**。`--self-test-brand-assets` 在 `main.swift` 注册并在清单中 |

## 3. 独立验证的两项（原自测未覆盖）

1. **应用图标 `.icns`**：`iconutil --convert iconset` 解出全部 10 个尺寸（16/32/128/256/512 各 @1x 与 @2x），magic 为 `icns`。PNG 为 1024×1024 且带 alpha。体积由 1.9MB 降至 182KB 是扁平化图形压缩更好，非资源缺失。
2. **`ZYZHMark` 整段删除**：曾用于 `CodexAccountManagerView:233` 与 `SettingsPanelView:97`。工作树已无任何引用，确认是品牌改名为 `AHBrandSymbol` 的完整替换（现 6 处使用），**不是未申报的功能移除**。

## 4. 对抗审查发现

### 发现 A（真实缺陷，未改）

`Sources/CodexUsageWidget/UI/TokenTotalsHeader.swift:134` 硬编码人民币汇率：

```swift
value: String(format: language.text("≈ $%.0f · ¥%.0f", "≈ $%.0f · ¥%.0f"), cost, cost * 6.8)
```

- 汇率 `6.8` 无来源、无配置，会随时间漂移，而界面把它呈现为具体金额。
- `README.md` 的口径是「接口未提供币种和换算时不标为美元」，即不发明换算。
- 虽然前缀有 `≈` 且标题为「API 等效估算」，但一个硬编码常量仍会产生看起来精确的错误数字。

**未修改**：这属于产品口径决定（是否显示人民币、汇率从哪来、是否可配置），需用户裁定。建议至少改为可配置常量或去掉人民币一行。

### 发现 B（措辞不实，未改文档）

两份交接文档都写「去掉 Codex 页 `minHeight: 188`」，但 `CodexAccountManagerView.swift:1624` 仍有：

```swift
.frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
```

经核查这是**另一张卡**（5h/7d `QuotaDetailTile` 双栏，布局仍是双栏，minHeight 合理），旧总量卡的 `minHeight: 188` 确实已删。所以实现正确，只是文档措辞会让人以为文件里再无该值——后续接手者可能误删。建议文档改为「去掉**总量卡**的 `minHeight: 188`」。

### 发现 C（已修）

`AHBrandAssetsSelfTest` 的文档注释声称校验「the codexU MIT attribution required by the license」，但代码只校验了身份常量与运行时 PNG，**既没有校验任何归属文本，也没有校验 Finder/Dock 实际使用的 `.icns`**。

本轮已把它补成真校验（见第 5 节）。

### 发现 D（次要，未改）

`HubAccountTaskStatus(phase:updatedAt:)` 不传 `blockDetail` 时，`.unavailable` 会推断为 `.hubOffline`。若真实原因是缺少账号映射，界面会给出不准确的阻塞原因。仅影响文案准确性，不影响 `blocksLocalCLI` 或任何门禁。

## 5. 本轮改动（仅一处文件）

`Sources/CodexUsageWidget/Domain/AHBrandAssetsSelfTest.swift`：

- 文档注释改为准确描述实际校验范围。
- 新增 `.icns` 校验：`AiGoodBro.icns` 必须存在、可解码、且保留 ≥512px 表示（Makefile 在打包时把 `Resources/codexU.icns` 重命名为 `AiGoodBro.icns`）。
- 新增 MIT 归属校验：打包内 `THIRD_PARTY_NOTICES.txt` 必须含 `shanggqm/codexU` 与 `MIT License`。

改动后已重跑格式检查、构建与 29 项自测（结果见上表）。

## 6. 仍未真实验证（必须标出）

- 真实主窗口 / 菜单栏弹出、pin、collapse、窗口层级
- banner 点击是否真的打开自动化中心并落到「重置消息」
- 各 Hub phase 的 help 悬停与 VoiceOver 朗读
- 设置页新字号下的真实点击热区
- 档位 popover 真实高度
- 任务概览浮窗真实弹出（现无独立 fixture）
- 真实登录、切号、重置卡兑换、通知送达、CLI 启动

上述均需用户授权安装/启动后才能验证；本轮禁止覆盖正在运行的应用。

## 7. Windows 工作区

`windows/` 下的未提交改动属于 Windows 移植任务（切片 S1–S4），与本轮 UI 无关，已在独立分支 `codex/windows-agenthub-0911v1` 推送。本轮**未将其计入 UI 改动**，也未还原或修改。
