# 共享占用与恢复

`preflight` 和 `refresh` 不预约。进入已授权工作准备时，使用 `reserve`，由 App 对当前身份与工作范围取得现有共享 guard，再生成绑定 actor、运行时、scope 和任务正文的单次 lease。有效期以服务端返回值为准，不能自行延长。

`run` 的 request ID 与原 lease、selector、正文必须一致绑定；request ID 为 64 位小写十六进制，不能复用于不同请求。调用先写持久 Pending，再转移同一 guard 到 App Hub Session，才创建和批准任务。客户端断线不会释放已经转移的占用。

收到 unknown、异常或丢失回执时保存原 request ID，只执行 `status --operation-id <原run的request ID>`。查询用独立 request ID。状态查询不会自动重发创建或批准；重启后证据不足仍可能 unknown，不从缺失记录猜测未执行。

`cancel-reservation` 只针对本 actor 尚未提交的 lease。已提交任务应在 App 中使用对应任务的取消/不确定状态处理，并保留真实进程终止证据。只有完整匹配任务、账号、项目、action 的终态证明才能释放 guard，不能用同 ID 的陌生行代替。

同账号的其他工作、身份切换或旧未知任务会阻止新准入。不要杀其他进程、改全局认证或手动删除 journal/锁。任务已退出不代表用户接受成果。
