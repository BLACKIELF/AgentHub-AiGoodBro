---
name: multi-agent-management
description: 使用已运行 AiGoodBro 的原生账号与任务范围，通过 Windows Companion 执行显式预检、刷新、预约、运行和结果状态核对。
---

# AiGoodBro Windows 配套调用工具

先确认用户给定的任务、账号和项目范围。在 AiGoodBro 选择已经登记的 Codex 账号与工作目录，并连接现有任务服务。这里的 Python 程序只是一次性 IPC 客户端，不启动应用、Hub、CLI 或第二个模型运行器，不复制凭据，也不切换系统账号。

使用安装后 `config/runtime-python.txt` 指向的已验证 Python，以 `-I -B` 执行 `bin/next-dispatch.py`。具体参数见[运行环境](references/runtime-setup.md)，共享占用和断连处理见[协作协议](references/coordination.md)。仅查状态不授权新任务。

1. 用 `preflight` 核当前已连接的数字 profile ID 和同一项目；需要新的账号证据时显式 `refresh`，然后再预约。失败保持未启动，不能从旧快照或界面绿色猜测可用。
2. 已有任务执行授权后，用 `reserve` 提交准确的任务正文并保存 lease ID。正文只从标准输入读取 UTF-8 字节，最多 65536 字节，不放到参数、日志或公开回执。
3. 用新的 request ID、同一 selector、同一正文和原 lease ID 执行 `run`。原生后端从当前身份、目录、保存偏好与占用派生权限；请求中的自称批准不授予权限。既有合法授权不增加逐次 GUI 确认。
4. 写入后断线、超时或响应不匹配一律按 `unknown` 处理，只用 `status` 查询原 operation ID，不能重发 `run`、换 request ID 或重建任务来试探。
5. `accepted` 只表示原请求已获确认，不是工作完成。`awaitingAcceptance` 还需实际检查产物；`uncertain` 继续占用。`cancel-reservation` 仅撤销尚未提交的预约，不能据此称任务已停止。

数字 profile 必须与 App 已连接账号一致。当前客户端不接受字母编号、账号别名或本次 model/effort/tier 覆盖；不支持的参数必须报告，不能忽略后偷偷执行。配套资源完整也不证明 Windows 原生能力已通过验收。

不读取或改写全局认证、浏览器 Cookie、真实聊天；不自动使用重置卡、邀请好友、发送飞书/微信或调用其他服务商。权限、费用、人工审批和用户停止指令继续有效。其他工具能力见[连接清单](references/onboarding-login.md)，不得把这个客户端当成原聊天 owner 控制器。
