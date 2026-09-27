# 公开重置预告自动推送 · 0926v3

相较 0926v2，增加 codex-resets.com 尚待来源确认的预告自动推送，并将预告投递状态与已完成重置公告分开保存。目标仅为 macOS App；本机覆盖安装已完成，未推送代码或发布下载包。

## 行为与安全边界

- HTML 预告解析结果接入现有 monitor。独立的 `public-reset-forecast-delivery-v1.json` ledger 首次有效观察只建立基线；之后仅将 `announcedAt` 比水位更新的新公告设为待发送。预告升级成已完成公告时，仍由原 completed ledger 管理，不重复共用阶段状态。
- 发送 DTO 只包含来源帖 ID、来源发布时间、可选的最晚时间与已校验来源链接；不包含抓取时间或页面正文。每次网络发送前先持久化 `sending` 阶段；崩溃、传输结果不明或服务器错误转为 `uncertain` 并禁止自动重试，明确可恢复的失败才保留待处理状态。
- 继续使用既有功能开关、Feishu 授权、Keychain 与 URL 白名单。显式命令 `--send-authorized-public-reset-update` 同时检查 API 与 HTML，并依据真实 `announcedAt` 选出最新候选；`fetchedAt` 不参与排序。

## 构建、测试与安装

使用已验证的 Command Line Tools 和 macOS 26.5 SDK 构建，避免默认 Xcode 27 对既有无关 `Color.blendMode` 代码产生歧义：

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools make build \
  BUILD_DIR=.local-artifacts/reset-messages-0926v1/build-models \
  SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  TOKEN_MONITOR_OFFLINE=1
```

全源构建与包内资源／签名校验通过。修复测试层对 JSON 转义 URL 的断言后，以下两项自测均通过；没有读真实钥匙串，也没有发测试通知：

```sh
scripts/run-self-tests.sh --skip-build --build-dir .local-artifacts/reset-messages-0926v1/build-models --only feishu-webhook
scripts/run-self-tests.sh --skip-build --build-dir .local-artifacts/reset-messages-0926v1/build-models --only token-monitor-ui
```

审阅 `make -n -o build install` 后运行事务式安装脚本 `.local-artifacts/reset-messages-0926v1/install-forecast-reviewed.sh`。重复项核对仅找到 `/Applications/AiGoodBro.app`；覆盖安装成功。安装包为 **9.6.11（60）/ 0926v3**，Bundle ID `com.blackielf.codex-account-manager-next`，strict deep codesign 验证通过（ad-hoc 签名）；候选与安装主程序 SHA-256 均为 `243e6f8cf0d3a9b28b47bf80d459a38e6a3423125cf08a5ba82e74c71ab55453`。

通过 CUA 从精确安装路径启动。首页显示「重置预告 · 待确认」、蓝色「今日新消息」、来源 `codex-resets.com` 与 2026-09-26 08:07（北京时间）发布时间。另一个独立的「AiGoodBro 消息」区域显示其公告源暂不可用；这不是 codex-resets.com 重置预告检查状态，重置卡显示上次成功检查时间为 18:08（北京时间）。本轮未打开模型选择器。

安装前现状与安装后核对的 auth/config 哈希、模型偏好摘要、所选 profile 摘要及 12 个 profile 数量均相同。与更早安装前快照比较时，auth 哈希和所选 profile 摘要已在本轮安装前出现差异，来源未判定；旧快照已保留，未回写认证或偏好文件。核验记录均只保存哈希、文件大小、时间与数量，未保存凭据内容。

今天的同一条预告已有先前人工发送回执 `.local-artifacts/reset-messages-0926v1/feishu-reset-forecast-receipt.json`（HTTP 200、code 0）；本轮安装与 CUA 验收没有重复发送，也没有以该回执证明自动发送。公开 `main` 仍是 9.6.1（50）/0915v5；不得把本机候选称为已公开下载。

构建、安装和隐私边界回执位于 `.local-artifacts/reset-messages-0926v1/install-forecast-receipt.json`、`self-test-forecast-0926v3-results.json`、`build-forecast-0926v3.log`、`install-forecast.log` 与安装前后 invariants JSON。旧的 [0926v2 记录](reset-models-0926v2.md)保留原验收事实。
