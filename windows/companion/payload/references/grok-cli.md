# Grok 与其他服务商的边界

本 Companion ABI 当前固定连接 App 的 Codex 任务范围，不提供 Grok CLI 调用，不接受 Grok 账号、模型或 token。不要把 Codex 的 selector、额度窗口或任务 lease 套到其他服务商，也不因请求失败静默换服务商。

用户指定 Grok 时，应使用该任务已明确配置并验证的独立工具/网页账号池入口，单独核对其身份、能力、费用与交付。配套文件中的这一说明不等于该入口已经登录或实测。没有对应能力就准确报告限制；不得在本 launcher 增加任意 shell 或自行启动第二个 runner。
