# AiGoodBro 1002v2 gallery

This gallery belongs to the 9.6.63 (113) source candidate. The PNGs were rendered on macOS from the candidate’s native SwiftUI/AppKit components with synthetic fixtures. They are product previews, not live screenshots: account identities, balances, dates, task names and provider states are fabricated for layout coverage.

The standalone proxy-window frame in production now uses a transparent full-size titlebar and one rounded glass surface. The `proxy/` images are direct SwiftUI content previews and do not include the system traffic-light frame; a real AppKit frame still needs a normal user restart to verify.

The gallery contains 94 Chinese and English home/account/provider/settings/setup/login views, usage surfaces, project workbench states, and the complete light/dark palette set. Dimensions and SHA-256 checksums are in [`manifest.json`](manifest.json). The old real captures remain in [`0929v2`](../0929v2/README.md) and are labeled with their original build.

## Home and accounts

| Home / 主页 | Accounts / 账号 |
|---|---|
| ![Compact home, synthetic preview](home/compact-zh.png) | ![Account cards, synthetic preview](accounts/cards-zh-dark.png) |
| ![Rows, synthetic preview](home/rows-dark.png) | ![Account rows, synthetic preview](accounts/rows-en-dark.png) |

## Proxy and workbench

| Proxy / 反代 | Project workbench / 项目工作台 |
|---|---|
| ![Proxy controls, synthetic preview](proxy/zh-dark-830.png) | ![Project workbench, synthetic preview](workbench/workbench-900-dark.png) |

## Settings

Each settings page has a Chinese and English preview.

| Page | 中文 | English |
|---|---|---|
| Appearance / 外观 | [预览](settings/appearance-zh-dark.png) | [Preview](settings/appearance-en-dark.png) |
| Workspace / 工作台 | [预览](settings/workspace-zh-dark.png) | [Preview](settings/workspace-en-dark.png) |
| Menu bar / 菜单栏 | [预览](settings/menuBar-zh-dark.png) | [Preview](settings/menuBar-en-dark.png) |
| Automation / 自动化 | [预览](settings/automation-zh-dark.png) | [Preview](settings/automation-en-dark.png) |
| Edge dock / 侧栏 | [预览](settings/edgeDock-zh-dark.png) | [Preview](settings/edgeDock-en-dark.png) |
| Floating bubble / 悬浮球 | [预览](settings/floatingBubble-zh-dark.png) | [Preview](settings/floatingBubble-en-dark.png) |
| Token Monitor / 用量 | [预览](settings/tokenMonitor-zh-dark.png) | [Preview](settings/tokenMonitor-en-dark.png) |
| About / 关于 | [预览](settings/about-zh-dark.png) | [Preview](settings/about-en-dark.png) |

## Setup and device login

The five setup steps and twelve device-login states are available in both languages. Login states are synthetic; they contain no valid login code or live authorization link.

| Step | 中文 | English |
|---|---|---|
| 1 | [预览](setup/zh-dark-step1.png) | [Preview](setup/en-dark-step1.png) |
| 2 | [预览](setup/zh-dark-step2.png) | [Preview](setup/en-dark-step2.png) |
| 3 | [预览](setup/zh-dark-step3.png) | [Preview](setup/en-dark-step3.png) |
| 4 | [预览](setup/zh-dark-step4.png) | [Preview](setup/en-dark-step4.png) |
| 5 | [预览](setup/zh-dark-step5.png) | [Preview](setup/en-dark-step5.png) |

[Device-login states / 登录状态](login/) · [Provider views / 工具账号页](workspace/) · [Usage surfaces / 用量浮层](usage/)

## Themes

Each built-in theme has a light and dark preview. Palette names match the application’s language labels.

| Theme | Light | Dark |
|---|---|---|
| 青花瓷 · Blue & White Porcelain | ![Blue & White Porcelain light](themes/codexu.blue-white-porcelain-light.png) | ![Blue & White Porcelain dark](themes/codexu.blue-white-porcelain-dark.png) |
| 默认 · Default | ![Default light](themes/codexu.default-light.png) | ![Default dark](themes/codexu.default-dark.png) |
| 敦煌飞天 · Dunhuang Apsara | ![Dunhuang Apsara light](themes/codexu.dunhuang-apsara-light.png) | ![Dunhuang Apsara dark](themes/codexu.dunhuang-apsara-dark.png) |
| 故宫红墙 · Forbidden City Red | ![Forbidden City Red light](themes/codexu.forbidden-city-red-light.png) | ![Forbidden City Red dark](themes/codexu.forbidden-city-red-dark.png) |
| 液态键帽 · Liquid Keycap | ![Liquid Keycap light](themes/codexu.liquid-keycap-light.png) | ![Liquid Keycap dark](themes/codexu.liquid-keycap-dark.png) |
| 蒙特雷曙霞 · Monterey Dawn | ![Monterey Dawn light](themes/codexu.orchid-dawn-light.png) | ![Monterey Dawn dark](themes/codexu.orchid-dawn-dark.png) |
| 千里江山 · A Thousand Li of Rivers | ![A Thousand Li of Rivers light](themes/codexu.thousand-li-landscape-light.png) | ![A Thousand Li of Rivers dark](themes/codexu.thousand-li-landscape-dark.png) |
| 紫蓝流光 · Violet Glow | ![Violet Glow light](themes/codexu.violet-glow-light.png) | ![Violet Glow dark](themes/codexu.violet-glow-dark.png) |
| WAICY 流彩 · WAICY Sunset | ![WAICY Sunset light](themes/codexu.waicy-light.png) | ![WAICY Sunset dark](themes/codexu.waicy-dark.png) |

WAICY Sunset is a color-token-only adaptation of the inspected badge-candidate colors. No logo, mascot, badge artwork, texture or font is copied, and the palette does not imply official endorsement.

## Provenance and limits

The renderer used temporary homes and fake stores; it did not read live provider data, call a paid model, send a notification, use a QR code or modify credentials. The preview receipt and source evidence remain local under the ignored QA artifact directory; private paths and raw runtime logs are intentionally not published.
