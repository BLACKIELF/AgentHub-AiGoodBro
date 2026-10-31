# 运行环境与真实调用入口

仅使用 App 已验证的 Windows Python 3.9+。检查覆盖标准库 ssl、sqlite3、ctypes、msvcrt 和 Asia/Shanghai 时区数据；不自动下载或安装 Python。Codex CLI 与 App Hub 沿原有原生选择和验证路径。

先在 App 内选择已登记账号和项目、连接任务服务，再执行“准备”查看差异，随后确认安装。检查本身不会启动 Receiver 或写来源绑定；确认沿相同流程建立本 App 的私有来源绑定与受控监听。不需要另开模型 runner，也不增加每次 run 的 GUI 审批步骤。

入口参数：

- `preflight --request-id <64位小写hex> --profile-id <数字ID> --project <同一绝对项目目录>`：读取当前 scope，成功只表示该检查时刻可准备。
- `refresh` 使用同样参数，显式读取官方身份/额度；不是纯离线操作，须在用户授权范围内执行。
- `reserve` 使用同样参数，并从标准输入读取任务正文；保存返回的 leaseId。
- `run` 增加 `--lease-id <原lease>`，原样重用 selector 与正文，使用新的 request ID。
- `status --request-id <新ID> --operation-id <原run的request ID>`：只查原持久请求，不重新提交。
- `cancel-reservation --request-id <新ID> --lease-id <未提交lease>`：只取消本 actor 的准备预约。

所有参数传给 `bin/next-dispatch.py`，前置 `python -I -B`。request ID 不能复用于不同动作。正文通过 UTF-8 标准输入传递，不在命令行拼接。写后 unknown 保持防重，退出码 3 不代表未发生提交；退出码 0 也不代表成果已验收。

三个 scripts 入口仅将指定方法委托给同一 launcher：preflight 只接 preflight/refresh，activity 接 reserve/status/cancel-reservation，invocation 接 reserve/run/status。它们不拥有独立凭据、账号配置、服务或任务执行器。
