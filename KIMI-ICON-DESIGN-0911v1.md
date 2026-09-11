# AiGoodBro 图标设计说明 · 0911v2

任务来源：用户否决 0911v1 C2（「图标不好看」），要求先吃透产品背景再做，并突出 **AiGoodBro** 与 **工作台 reset 通知**。

Kimi CLI 本轮 `--auto -p` 不兼容，已改用 `-y -p` 派到 `camnext-0911v13-kimi-icon`。本候选工作区同时按同一 brief 落地可安装资源，避免覆盖安装被图标卡住。

## 产品背景（设计约束）

AiGoodBro 是额度 / 重置窗口 / 下一次任务的 macOS 工作台，不是聊天机器人。短名 AH，工作台名 AgentHub。用户真正记住的差异点是 **5h/7d 窗口会转回来**，以及公开重置公告和重置卡。图标必须让人感到：这是一个工作台，而且它管 reset。

## 候选与对抗审查

预览在 `docs/images/ah-brand-0911v1/candidates/`：

- **C4 空心枢纽**：把 C2 实心圆改成圆环。比脏点干净，但仍是「字母 + 圆」，读不出工作台。淘汰。
- **C5 工作台内框 + 重置圆环**：入选。外层 macOS squircle 是 App；内层圆角窗是 AgentHub 工作台；AH 连字是 AiGoodBro；横杠上的空心圆环是窗口循环。16–1024px 可辨，不会被看成脏点或小写 e。
- **C6 缺口回转箭头**：reset 语义最直，但 256px 已像字母 e，小尺寸更碎。淘汰。

旧 C1/C2/C3 不再作为候选。C2 被否：实心圆像瑕疵，且没有任何工作台 / reset 记忆点。

## 最终选择：C5

- 源：`scripts/generate-ah-brand-icons.py`，`FINAL_VARIANT = "c5"`。
- `AHBrandSymbol` 同源：彩色底板 + 内框 + 空心枢纽；模板版只有字形和圆环。
- 底板仍是品牌蓝纵向受光，略收深，避免社交蓝贴纸感。

## 复现命令

```sh
python3 scripts/generate-ah-brand-icons.py --candidates docs/images/ah-brand-0911v1/candidates
python3 scripts/generate-ah-brand-icons.py --final
python3 scripts/generate-ah-brand-icons.py --board docs/images/ah-brand-0911v1/ah-brand-acceptance-board.png
```
