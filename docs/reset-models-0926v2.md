# 重置消息与模型目录 · 0926v2

相较 0923v9：首页重置区仅保留 codex-resets.com 的公开预告与公告；移除该区个人重置卡数量及常驻检查说明。当日发布的消息显示「今日新消息」和蓝色背景／边框，以北京时间自然日计算，每分钟更新，跨日自动恢复普通样式。折叠时仍保留今日提示。相较本任务 0926v1 候选，补充 GPT-6 Sol / Luna 模型目录与内置档位更新，并按用户要求先清理今天之前的旧应用及安装包。

## 当前交付状态

- 源码分支：`codex/reset-messages-0926v1`，基线 `debedc32bbc1d619e6be184643a3a14f6d239393`。
- 目标版本：macOS **9.6.10（59）**，ReleaseName `0926v2`。
- 用户已明确授权完成后覆盖安装。**2026-09-26 13:52（北京时间）已安装 `/Applications/AiGoodBro.app`**，版本、严格签名与候选二进制指纹均已核对。启动实机验收时 Mac 再次锁屏；实际菜单和高亮显示仍待解锁后核对，不能视为已完成原生窗口验收。

## 旧版本清理

以北京时间 2026-09-26 零点和应用二进制／安装包修改时间为界，结合 Bundle ID、包内文件及 Git 跟踪检查，237 项旧应用、旧预览、安装包与构建残留已移入系统废纸篓。已逐项核验原路径消失、废纸篓项目存在；保留今天的 0926v1 候选、源码和账号数据。没有清空废纸篓。

清理清单与恢复映射保存在验证目录的 `old-versions-trash-receipt.json`、`old-versions-trash-receipt-extra.json` 和 `old-versions-trash-receipt-binaries.json`；汇总见 `old-versions-cleanup-summary.json`。原正式应用及其备份也在该映射中，不再位于旧备份路径。

## 模型目录

新增真实模型 ID `gpt-6-sol` 和 `gpt-6-luna`，位于 GPT-6 Astra 后。Sol 支持至 Ultra，Luna 支持至 Max，能力已与本机官方模型缓存（2026-09-26）核对。中蹬内置默认升级为 GPT-6 Sol / High + GPT-6 Luna / Max，慢蹬为 GPT-6 Luna / Max。旧 5.6 模型值和显式自定义预设保持可解码，不改写真实用户配置；未保存自定义覆盖的内置档位跟随新版默认。

## 实现与验证

修复公开预告的 `data-scheduled-for=""`：合法的「时间待公布」现在保留为未确认预告。缺失必要属性、非法非空日期及不可信来源仍会被拒绝。当天判断使用公告本身的发布时间，不使用刷新时间，也不提前高亮未来消息。

真实网站 HTML 经原生 URLSession 获取后，旧解析器返回 `invalidResponse`；修复后识别到公告 `2103637477760311522`，发布时间为北京时间 **2026-09-26 08:07:13**，计划时间未公布。历史最新记录仍为 9 月 23 日，不应高亮为今天。

0926v2 主程序优化编译及完整打包通过；五组原生自测均返回 0：`profile-store`（含序列化、模型能力、CLI 主／子模型参数与 Terminal launcher）、`feishu-webhook`（含公开预告解析）、`token-monitor-ui`（含北京时间日期边界）、`main-window-layout`、`workspace-screenshot`。Python 派单预检纯自测与语法编译、随包 Hub 定向测试及完整 `go test ./...`、SOURCE 摘要校验、代码签名、运行时资源校验与 TokenMonitorEngine 打包烟测均通过。

随包 Hub 保留升级前已冻结任务的精确旧 5.6 模型组合、角色摘要和原 ActionHash；未知或不一致的冻结参数仍会被拒绝。原生模型选项及直接 CLI 参数已更新；已有独立 Hub 服务和全局 Skill 运行副本未在本次 App 安装中部署更新，单纯更新 App 不代表这些独立组件已经升级。

采用与已安装版本一致的 macOS 26.5 SDK；默认 Xcode 27 SDK 会触发现有 `AHBrandPresentation.swift` 的 `Color.blendMode` 歧义，因此未改动该无关模块。

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools make build \
  BUILD_DIR=.local-artifacts/reset-messages-0926v1/build-models \
  SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  TOKEN_MONITOR_OFFLINE=1
```

## 安装与回退依据

本次验证资料保存在 `.local-artifacts/reset-messages-0926v1/`，包括真实页面、解析前后日志、构建及自测日志、源码指纹、清理和安装回执。今天的消息候选保留在 `build/AiGoodBro.app`；合并模型后的目标在 `build-models/AiGoodBro.app`。

- 原版本：9.6.9（58）；SHA-256 `7a960b53c9ae7e5787bbcf5d0fff7a42a169041babcc0d1aa96939d67f860cf8`。
- 0926v1 消息候选二进制：SHA-256 `2cc213dad47a9b4d5e87e3358f665b6829aa765ef510f228e8367e3285ffe081`。
- 已安装 0926v2 二进制：SHA-256 `9de3070edf94040d1eef6a93d8b748446694daad5942908cdc7660bf56796a11`，与已测试候选相同。安装回执为 `install-models-receipt.json`。
- 目标：`/Applications/AiGoodBro.app`。安装脚本来自项目 Makefile 的现有事务式替换流程；先核对重复项、签名及进程空闲，再替换。回退时先退出应用，再用已核验备份替换同一目标。

GPT-6 Luna / Max 完成解析、界面及模型调用适配。全局认证、全局运行配置及已有账号模型偏好均通过安装前后摘要核对，未发生变化。安装后的真实窗口验收待 Mac 解锁；当前没有运行中的 AiGoodBro 进程。
