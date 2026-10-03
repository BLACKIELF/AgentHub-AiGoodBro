# 剩余 1% 暂停与切号 · 0927v1

当前补充：暂停、切换与续做边界已在 [0927v3](ai-goodbro-2.0-0927v3.md) 再次验证并覆盖安装。指定 Pro 的单次周额度路径与长期自动化分开；用户选择保留当前 20 倍账号，本轮仅做隔离测试。以下为初版实现记录。

目标：桌面账号官方 5 小时或周额度剩余 ≤1% 时，先暂停正在运行的本机 Desktop 任务，确认停止后通过 AiGoodBro 现有事务切换合格备用账号。按用户补充要求，切换与历史核验成功后可以自动继续原任务；也可关闭自动续做，点击“继续原任务”。

## 复用研究（2026-09-27）

通过 AnySearch general 与 code.snippet 查找“Codex auto switch account quota interrupt desktop”“turn/interrupt”“codex account switch pause resume quota threshold”，随后通过 GitHub API、固定提交源码复核。

| 候选 | 证据与判断 | 决策 |
| --- | --- | --- |
| OpenAI Codex，126,581 stars、未归档 | [固定提交](https://github.com/openai/codex/tree/6e1ab4d294cdf1d2606a91bf1acf6de0f0959c7a)；Apache-2.0 LICENSE；[turn interrupt 测试](https://github.com/openai/codex/blob/6e1ab4d294cdf1d2606a91bf1acf6de0f0959c7a/codex-rs/app-server/tests/suite/v2/turn_interrupt.rs)核对当前 turnId，错误 ID 拒绝。中断回执与完成通知分开。 | 首选：使用官方协议，不复制整套客户端。 |
| Codex_AccountSwitch，250 stars、未归档 | [webview_host.cpp](https://github.com/isxlan0/Codex_AccountSwitch/blob/21ac43ff4c2e222ac61aa56295aa76129249d222/Codex_AccountSwitch/webview_host.cpp)，MIT；主要为 Windows WebView，低额度提醒默认10%、冷却30分钟。 | 参考防抖思路。现有 AiGoodBro 已有额度、身份、互斥与回滚，无需引入另一管理器。 |
| codex-switch，1 star、未归档 | [Bash 脚本](https://github.com/jonesfernandess/codex-switch/blob/4e6a0aae1939110a39c5fdc1b583114f3d7ef8df/codex-switch)；CLI 退出/429 后轮转并重试，未确认根许可证。 | 不复制。使用 Desktop 原 thread/turn 元数据接续，避免重跑整段 CLI 提示词。 |

星数为研究时 API 返回值，只作背景。前三个候选的源码证据没有证明本机运行效果。没有安装研究对象或引入付费调用。

## 接入方式

1. 新开关“剩余 1% 自动暂停并换号”是独立 opt-in，开启后同时启用既有自动换号并将两个触发线固定为1%。旧版本的提醒/空闲切号设置不自动获得中断任务权限。
2. 来源与候选额度必须完整、新鲜（45秒内）且读取成功；候选两个窗口可用、触发窗口至少30%。先取得已有账号维护互斥，再发送任务暂停请求。
3. 使用 AiGoodBro 已有的本机 AF_UNIX app-server 连接。只允许 thread/loaded/list、thread/read、thread/turns/list、turn/interrupt；分页只读取最近一个 turn 的无内容元数据。未知方法/超时/断开一律停止。
4. 通过 thread/read 确认正在运行的根任务；子任务由已确认的根任务中断。父任务缺失、未知状态或所有者关系成环时不操作。请求携带精确 threadId + 当前 turnId，不发 kill 信号。
5. 中断回执不是完成。重新读到全部停止，再读完整任务快照并复核身份、额度与启用状态，才进入既有切号流程。暂停失败或新任务出现则保留当前账号；已暂停任务不会自动重跑。关闭开关/取消也会阻止后续中断与切号。
6. 在任何中断前，将精确 threadId/turnId 清单和目标复合身份哈希持久保存到私有恢复记录。写入失败不暂停；部分暂停失败仍保留清单，不自动标记切号成功。
7. 只有既有切号事务、重启身份和历史核验成功后才将本批标记 ready。重新确认当前身份、完整新鲜额度、共享 daemon 后，逐项检查该任务没有新轮次，最新轮次确为 interrupted；调用官方 thread/resume 恢复已有上下文，再用 turn/start 提交简短续做指令。保留原对话，不创建新任务，不覆盖模型或批准策略。
8. 每项在 turn/start 前持久记录 attempted；超时、未知结果或进程退出后都不会自动重发。同一已完成轮次或已出现新轮次时跳过。应用重启不自动续做，只保留按钮；待处理批次不会被下一次切号覆盖。

## 验证状态

最终宿主编译和33组完整原生自检通过，已包含在9.6.13(62)安装版中。阈值、过期/未知数据拒绝及7组不连接真实 daemon 的暂停协议模拟通过（正常停止、接口不支持、只有回执未停止、出现新任务、撤销开关、子任务父级未知、恢复记录写入失败）。续做另外通过11组隔离模拟，包括目标状态核验、暂停记录恢复、已完成任务跳过及超时防重。没有暂停真实任务、没有切真实账号、没有为测试发送任务提示词，也未将协议模拟描述为实际切号验收。
