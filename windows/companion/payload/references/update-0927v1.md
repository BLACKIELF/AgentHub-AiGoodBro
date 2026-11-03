# Windows 布局兼容与恢复

Windows 资源来自 Mac build165 的配套工具合同，采用真实 Windows 一次性 Python IPC 客户端，不包含 Darwin shell、launchd 或 direct 模型 runner。固定载荷为 16 项；安装器另生成 runtime-paths.json 和 runtime-python.txt 两份实际运行配置。

Mac 的 dispatch-codes-v1.json 与 dispatch-policy-v1.json 在这里没有第二份可执行权限来源，所以不生成新文件，也不覆盖用户已有文件。账号和策略读取 App catalog/workflow。字母别名、按套餐排除、绝对 notAfter 截止和本次模型参数覆盖未因布局变化而自动实现，仍应按能力差异报告。

已有安装只更新明确托管的 9 项与 SKILL 中托管区块；其余用户正文保留。对比与确认期间内容、目录身份、资源 pin 或运行时变化，必须重新准备。恢复只撤回本次仍与写入值一致的文件，遇到新修改则保留并报告冲突，不能递归清空用户 Skill。
