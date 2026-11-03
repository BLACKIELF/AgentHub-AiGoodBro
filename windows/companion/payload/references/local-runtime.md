# 本机入口与故障定位

安装后从 `config/runtime-python.txt` 读取 App 已验证的 Python 路径，以 `-I -B` 执行 `bin/next-dispatch.py`。客户端只读取同一安装目录的 `config/runtime-paths.json`；不使用旧 v1 文件名或任意 --pipe、--token、App 路径参数。

App 未运行、任务服务未连接或来源绑定缺失时报告不可用，不自动启动或收养其他服务。客户端按私有 locator 定位，再核对实际进程与已绑定 App 来源；locator 自报路径/哈希不能授予权限。

选择路径或 App 文件变更后重新在应用内核对。自动发现 Python 与显式选择同一文件仍是不同绑定；不能仅因 hash 相同复用已失效的旧 backend。

退出被取消时只恢复原授权的 Receiver 监听；不能创建新任务或重新绑定未知来源。停止结果不明时保留原 owner，不启动第二份。原任务的未知记录仍需查询原 ID。
