# Antigravity 接入 · 0923v1

新增工作台入口、官方桌面应用发现、活动账号额度读取及独立旧版 IDE 档案的只读关联。此前 Antigravity 仅在“尚未支持”目录中。

- 新版桌面：读取已运行官方应用的 `GetUserStatus` 和 `RetrieveUserQuotaSummary`，显示原始模型族／窗口、剩余额度和返回的重置时间。请求前后核对账号，变化时丢弃结果。
- 进程按内核路径、当前用户、启动时间、Google 签名和实际监听端口验证。网络只连接该进程的 `127.0.0.1`，禁重定向、代理、Cookie；HTTPS 为主，仅在同进程拥有指定扩展端口时尝试 HTTP。
- 不启动 Antigravity、不登录、不刷新 OAuth、不切换账号、不发送模型请求。缺失额度是未知，明确的 0 才显示耗尽；不将本地 token 消耗当余额。
- 独立档案只读取用户选定目录的 `User/globalStorage/state.vscdb`。该缓存是历史记录，不能证明最新额度或登录成功；显示的时间仅是缓存文件修改时间，官方额度记录时间未知。
- 已发现运行端点但在线读取失败时，直接返回不可用，不以历史缓存替代当前账号；无法识别所属账号的缓存不显示额度。仅无运行端点时允许默认环境显示明确标注的历史缓存。
- 本机核实安装版本为 2.15.0，Google 签名通过；采样时应用未运行。协议和解析完成纯 fixture 验证，未声称完成这个真实账号的在线额度验证。

协议依据（固定提交）：[CodexBar Antigravity 说明](https://github.com/steipete/CodexBar/blob/1c8657a083d542fbefec02f17d48c06b01bf099e/docs/antigravity.md)、[分组额度解析](https://github.com/steipete/CodexBar/blob/1c8657a083d542fbefec02f17d48c06b01bf099e/Sources/CodexBarCore/Providers/Antigravity/AntigravityQuotaSummaryParser.swift)、[OpenCode Bar 旧版缓存字段](https://github.com/opgginc/opencode-bar/blob/7aa109d6580ee045e99b55f4adbcbf29e68ec521/CopilotMonitor/CopilotMonitor/Providers/AntigravityProvider.swift)。当前两条上游实现都将缺失 fraction 与明确的 0 分开处理；没有凭缺省字段推定已耗尽。

验证入口：`python3 tests/test_antigravity_cli_quota.py`，使用合成数据，不读取用户凭据、不连接真实服务。
