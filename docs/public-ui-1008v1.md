# 公开界面资料 · 1008v1

核验日期：2026-10-08。本次只更新 GitHub 文档与对外展示素材。

## 当前版本范围

| 层级 | 已核验状态 | 对外展示 |
|---|---|---|
| GitHub 公开安装包 | [9.6.80 (130)，2.2 / 1006v3](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/v9.6.80) | 下载与发布说明继续指向该正式包 |
| 本机安装版 | 2.3.0 (137)，二进制与已验候选一致 | 尚未公开发行；没有把本地安装状态写成 GitHub 发布 |
| 后续 138 候选 | 已因窄窗英文布局回归被拒绝交付 | 不作为正式发布或截图依据 |
| 最新界面图片 | 137 正式渲染仍使用隔离合成数据；没有已核验可公开的最新实机图 | 先保留有依据的文字，待脱敏实机图核验后补充 |

Public downloads still target build 130. The verified local build 137 and later candidates are not public releases. No synthetic or concept image is presented as a current live screenshot.

## 双圈图片来源

被询问的「WAICY 流彩 / 5h 93% / 7d 73%」图片来自 1002v2 图册的主题色值展示卡，所属候选为 9.6.63 (113)。其生成器 [`PalettePreviewCanvas`](../Sources/CodexUsageWidget/Domain/PalettePreviewRenderer.swift#L134)固定使用 93 和 73 两个演示值；图册清单也标明 `syntheticOnly: true`。

这是主题预览画布，并非当前账号卡片或真实额度记录。双圈卡、旧图册和设计稿均已从当前公开树移除，未用另一张合成图替代。截图上的视频字幕可确认属于二次编排；现有证据未将该裁图片绑定到某个唯一成片文件。

## 旧资料到当前资料

| 原展示 | 处理 | 当前入口 |
|---|---|---|
| 中英文 README 的首页、账号、工具、项目、引导、反代及主题图片 | 删除 14 处旧图引用与图册导流 | 保留功能文字，明确公开 130 与本机 137 的范围 |
| 使用说明中的 113 列表图 | 移除旧图 | 保留现有操作说明 |
| 各版本图册、概念封面、合成预览、旧实机图 | 移除旧图片与生成清单；目录入口改为停用说明 | 本文与当前 README |
| 0923v7 / 0923v8 HTML 设计稿和效果图 | 停用公开旧预览 | 保留历史实现记录，不改生产组件 |
| 旧宣传草案与源码记录中的展示入口 | 移除旧图引用并标明历史范围 | 当前 README 与本次清理记录 |
| Release 正文及附件 | 当前唯一 Release 未引用旧图或演示视频，无需重复更新 | 130 安装包、ZIP 和校验附件原样保留 |

## 移除清单

以下为当前公开树移除的素材，不改写 Git 历史。所有原件、原目录说明及 SHA-256 已先保存到本地恢复归档并逐项校验。

| 原目录或文件 | 移除文件数 | 其中图片 / HTML | 逻辑字节 |
|---|---:|---:|---:|
| `docs/images/0904v2` | 5 | 5 | 376,311 |
| `docs/images/0905v1` | 4 | 4 | 991,439 |
| `docs/images/0905v3` | 25 | 24 | 3,631,854 |
| `docs/images/0907v3` | 10 | 10 | 3,398,801 |
| `docs/images/0909v4` | 8 | 6 | 10,852,132 |
| `docs/images/0910v1` | 7 | 6 | 6,858,213 |
| `docs/images/0927v6` | 2 | 2 | 540,438 |
| `docs/images/0929v2` | 6 | 6 | 1,778,652 |
| `docs/images/0929v4` | 1 | 1 | 204,724 |
| `docs/images/1002v2` | 95 | 94 | 92,797,033 |
| `docs/images/1002v4` | 7 | 6 | 1,232,919 |
| `docs/screenshot-0826v1-settings.png` | 1 | 1 | 692,457 |
| `docs/ui-preview-0923v7` | 9 | 9 | 1,992,463 |
| 合计 | 180 | 174 | 125,347,436 |

这些数值是移除素材的逻辑大小。原始软件工作树、Git 历史与恢复归档仍保留文件，不将其声称为磁盘空间回收。

## 保留范围与验证

Codex / Claude 卡片和列表、圆形额度进度、侧栏及菜单浮窗继续保留。本次未修改 Swift、Go、Stores、Services、Info.plist、运行资源或 Windows 源码，未改动软件版本、安装包、发布标签或正在运行的 App / 反代。

侧栏的反代详情提供运行状态、请求数、账号列表及每个账号的 5h / 7d 额度圆环、重置倒计时和点数；请求快照每分钟更新，额度为最近一次读取，缺少额度时显示「—」。详情可固定置顶，并保留反代设置入口。其展示来自现有 [`proxyContent`](../Sources/CodexUsageWidget/UI/TokenMonitorEdgeDockView.swift#L618)。

移动指针进入或切换侧栏条目时，会按「触控板轻触反馈」设置调用系统触感反馈；支持触感反馈的触控板可感受到轻触提示。已核对现有[触发位置](../Sources/CodexUsageWidget/Services/TokenMonitorEdgeDockController.swift#L630)与[设置开关](../Sources/CodexUsageWidget/UI/TokenMonitorEdgeDockSettingsView.swift#L204)。用户提供的当前局部截图用于确认这类界面，账号别名和点数未进入公开图片；静态截图不作为触感验收证据。

提交前验证包括：恢复归档逐项 SHA-256、移除目标不存在、文档链接与旧媒体引用扫描、差异范围与隐私检查，以及已公开 130 二进制的既有纯自测。PR 与 main 的必要 CI、合并后远端读回分别验证；文档更新不代替实机登录、额度请求或软件发布验收。

[中文 README](../README.md) · [English README](../README.en.md) · [公开版本说明](release-notes-v9.6.80.md)
