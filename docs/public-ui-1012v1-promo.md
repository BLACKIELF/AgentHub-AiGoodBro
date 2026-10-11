# README image sources · 1012v1

The Chinese and English READMEs show seven matching promotional scenes in their feature sections and collect the ten existing application screenshots at the end. Feature descriptions retain their existing product scope. The READMEs each give the demonstration notice once, before the first feature image.

中文与英文 README 前部按功能展示七个对应的宣传片场景，原有十张实际软件截图集中放在文末。功能说明保留现有范围；每份 README 只在第一张功能图前统一说明一次演示属性。

## Promotional image sources

All fourteen new images are 1920 × 1440 PNGs. Their account aliases, quotas, balances, countdowns and notification contents belong to the promotional script; they do not establish application installation, sign-in, current provider quota, real proxy requests, card redemption or message delivery.

The two languages have different image derivations:

- **Chinese:** the corresponding frame times are rendered from the existing Chinese `v3.html` scene source, with only the app-icon resource mapped to the previously approved half-body avatar. This keeps the source layout, text, values and camera timing while using the confirmed avatar. These are adapted source renders, not byte-identical frames from the Chinese MP4. The Chinese HTML source and original MP4 are not modified.
- **English:** the selected frames are decoded from the original English MP4 with FFmpeg and encoded as RGB24 PNGs. No crop, scale, retouch, added text or compositing is applied. The half-body avatar, perspective and any camera clipping are already in the video.

中文使用既有 `v3.html` 的同时间点渲染，只把 app-icon 资源映射为已确认的半身头像；英文使用原 MP4 的解码帧。中文图不能称为原 MP4 原样截图。原中文源码和两份视频均不因本次 README 配图而改写。

### Original videos

Both original videos are 48 seconds, 1920 × 1440 at 30 fps. The Chinese video remains available in its original form; the English package contains the English video and editable English showcase source.

| Video | SHA256 |
|---|---|
| [Chinese original · AiGoodBro-demo-1011v4.mp4](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.0/AiGoodBro-demo-1011v4.mp4) | `9af3abebd933dbab30f95419768717d862f2564373fde70df1cb2e17da761717` |
| [English original · AiGoodBro-English-1011v1.mp4](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.0/AiGoodBro-English-1011v1.mp4) | `e236788e272f5b722284b5505df2263dd70ef53bb3b962211a6258cd031e30b3` |

### Scene mapping

Frame indexes are zero-based; time is `frame_index / 30`. Chinese renders use the same scene time as the corresponding English decoded frame. The notification image is shown once in the WeChat section; the Feishu section links to it.

| README section | Frame / time | Chinese image | English image |
|---|---|---|---|
| 01 · Main UI / 主界面 | 1026 / 34.20 s | [dashboard.png](images/1012v1-promo/zh/dashboard.png) | [dashboard.png](images/1012v1-promo/en/dashboard.png) |
| 02 · Reset messages / 重置消息 | 282 / 9.40 s | [reset.png](images/1012v1-promo/zh/reset.png) | [reset.png](images/1012v1-promo/en/reset.png) |
| 03 · Local proxy / 本地反代 | 870 / 29.00 s | [proxy.png](images/1012v1-promo/zh/proxy.png) | [proxy.png](images/1012v1-promo/en/proxy.png) |
| 04 · Codex accounts / Codex 账号 | 957 / 31.90 s | [accounts.png](images/1012v1-promo/zh/accounts.png) | [accounts.png](images/1012v1-promo/en/accounts.png) |
| 06 · Token Monitor / 用量统计 | 669 / 22.30 s | [usage.png](images/1012v1-promo/zh/usage.png) | [usage.png](images/1012v1-promo/en/usage.png) |
| 10 · WeChat and Feishu / 微信与飞书 | 489 / 16.30 s | [notifications.png](images/1012v1-promo/zh/notifications.png) | [notifications.png](images/1012v1-promo/en/notifications.png) |
| 12 · Sidebar / 侧栏 | 791 / 26.3667 s | [sidebar.png](images/1012v1-promo/zh/sidebar.png) | [sidebar.png](images/1012v1-promo/en/sidebar.png) |

The [machine-readable manifest](images/1012v1-promo/manifest.json) records the derivation, source hashes, frame indexes, image dimensions, byte sizes and SHA256 of each delivered PNG. There is no new Chinese ZIP in this update. The [complete English package](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.0/AiGoodBro-Showcase-1012v1.zip) and [English showcase](showcase/1012v1/README.md) retain their English scope.

## Existing application screenshots

All ten existing screenshot files keep their original paths and bytes. Each README displays them once under its final **Actual app screenshots / 实际软件截图** section, with a single introduction giving capture provenance and limitations. No new application capture is claimed.

| Subject | Existing file | Capture source |
|---|---|---|
| Main UI / 主界面 | [home-live.png](images/1009v1/home-live.png) | Installed 2.3.0 (137) |
| Proxy status and sidebar / 反代状态与侧栏 | [proxy-status-edge-dock.png](images/1009v1/proxy-status-edge-dock.png) | User-supplied crop; no visible build number |
| Codex accounts / Codex 账号 | [accounts-home-137-crop.png](images/1009v2/accounts-home-137-crop.png) | Authorized lossless crop of the 137 home capture |
| Claude sign-in / Claude 登录 | [claude-login.jpg](images/1009v2/claude-login.jpg) | Installed 2.3.0 (139) |
| Usage / 用量统计 | [usage-home-137-crop.png](images/1009v2/usage-home-137-crop.png) | Authorized lossless crop of the 137 home capture |
| Tool guide / 工具连接引导 | [guide.jpg](images/1009v2/guide.jpg) | Installed 2.3.0 (139) |
| Reset-card settings / 重置卡设置 | [reset-auto.jpg](images/1009v2/reset-auto.jpg) | Installed 2.3.0 (139) |
| Notification settings / 通知设置 | [notifications-guide.jpg](images/1009v2/notifications-guide.jpg) | Installed 2.3.0 (139) |
| Sidebar settings / 侧栏设置 | [edge-dock-settings.jpg](images/1009v2/edge-dock-settings.jpg) | Installed 2.3.0 (139) |
| Appearance / 外观设置 | [appearance-settings.jpg](images/1009v2/appearance-settings.jpg) | Installed 2.3.0 (139) |

The [historical image record](public-ui-1009v2.md) and its manifests retain the original checksums, dimensions, crop coordinates and capture context. In particular, the reset-card image's 25-minute setting is a custom snapshot; the product default remains 30 minutes. The tool guide shows authentication configuration discovery, and the notification guide shows connection states; neither establishes a successful model call or message receipt. The proxy crop cannot be assigned to a particular build from its pixels.

## Verification scope

This README update checks matching scene and section mapping, one feature image per selected scene, ten preserved originals at the end of each language, one demonstration notice per README, relative links and anchors, PNG metadata and hashes against the manifest, and unchanged original screenshot bytes against the Git baseline. Image-source validation distinguishes the adapted Chinese source renders from the unchanged English decoded frames.

These documentation and image checks do not replace installation, real-account or device acceptance. No application code, old screenshot file, original video, release tag or software installer changes are part of this README image update.

[中文 README](../README.md) · [English README](../README.en.md)
