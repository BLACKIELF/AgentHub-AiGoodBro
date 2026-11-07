# 通知连接保留与升级兼容 · 1024v2

覆盖升级保留既有绑定、开关、会话游标和钥匙串服务名。没有迁移或重新保存用户密码。

- 飞书启动读取与通知设置修改使用独立生命周期，避免修改内容选项丢弃正在返回的读取结果。
- 成功的静默读取缓存于当前进程；后续投递不重复排队读取钥匙串。关闭、更换、移除和停止仍使缓存失效。
- 暂时忙、超时、钥匙串暂不可用不再误报为需要授权。读取失败以 2、10、30、最多 60 秒退避静默重试；不弹系统窗口、不自动发送测试。
- 微信打开设置只做静默读取。交互授权仅由“恢复连接”触发。后台会话更新保存失败时继续使用当前连接并重试保存最新状态；关闭或重新绑定会取消旧重试。
- 覆盖安装验证新包满足当前已安装包的 designated requirement 和相同 bundle identifier；失败保留旧包，防止签名身份漂移使钥匙串授权失效。

## 上游依据

Apple [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) 解释由 designated requirement 跟踪钥匙串访问及应用升级。Apple [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) 区分文件钥匙串与 Data Protection Keychain；后者需要对应 entitlement 和 provisioning profile。本次保持现有受保护存储，不引入无配置保证的迁移。

核对 [Tencent/openclaw-weixin](https://github.com/Tencent/openclaw-weixin/tree/874637a0dbc24050f72d1385add4fc6170a2d726) 的轮询退避、游标恢复和会话令牌处理。沿用已适配协议，不复制其明文凭据保存方式，不把通用拒绝码 -2 当作确定的登录过期，不重发结果不确定的消息。

## 验证范围

旧源码复现微信启动忙、超时、锁定后的不恢复，以及打开设置触发授权。修复后同一回归通过。真实 macOS Security 隔离测试验证同签名版本读取和更新旧测试项无需密码；不同身份被拒；测试项移除、钥匙串搜索列表恢复。测试仅使用合成凭据。

本机现有条目的历史 ACL、首次授权、锁定和用户撤销授权仍由 macOS 管理；不能承诺绕过系统确认。真实安装与消息收到须另行记录，源码或隔离测试不代表投递成功。保留上一版完整包和源码，回退只替换 App，不清空配置或钥匙串。
