# Codex Account Manager Next v9.5.3

Release name: 0905v3

Build: 15 · Date: 2026-09-05

## Highlights

- 与 0905v2 相比，重新设计整个设置界面：Next 品牌页头、五个直接可达的分区和低干扰页脚，移除继承的长表单、层叠卡片与大面积主按钮。
- 外观、菜单栏、自动化、工作区、关于各有清晰用途。主题用三张可点击预览呈现，小范围选项改为分段选择，保留原生键盘与选中语义。
- 菜单栏实时预览与恢复默认放在一起。暖号单独展示 5 小时与 7 天窗口、额度消耗及空闲门禁，不因打开设置而启动任务。
- 保留所有原有设置、存储键、账号数据、CLI 参数和安全回调；不新增第三方依赖。0905v2 的模型／强度一级菜单修正继续保留。
- 新增设置往返与分区标签回归测试，以及中英文、浅深外观共 20 张使用真实 SwiftUI 组件的 2× 隔离预览。

## Verification

- 最终 Apple Silicon 优化构建通过；25 组自测全部通过，包括新增设置分区与偏好往返测试。
- Swift 严格格式检查、macOS 兼容性静态检查、运行资源检查、plist 校验和 ad-hoc 签名验证通过。
- 内存风险扫描通过：本次未增加进程、管道、计时器或观察者入口。此项为静态风险检查，不等同于长时间内存观测。
- 5 个分区 × 中英文 × 浅深外观的 20 张原生 SwiftUI 2× 预览生成成功；检查了外观、菜单栏、自动化和关于页的代表性布局。文档附图为隔离演示数据，不是真实账号截图。
- 原位覆盖原来的 `build/CodexAccountManagerNext.app`，安装后版本为 `9.5.3 / build 15`；运行进程来自同一路径，未新增安装目录。
- 实际主窗口可读且进程持续运行。设置入口的自动化点击后，工具仍读取主窗口，期间曾出现一次原生连接中断；未出现新增 App 崩溃报告，但不能据此声称设置弹窗和五个标签的真实点击验收通过。
- 本地安装验收时源码尚未推送；随后按维护者要求整理本版源码、品牌文档与三平台文案，纳入同一次 `main` 推送。GitHub tag、二进制 Release 和社交平台发布不在这次授权内。
- 历史发布素材曾整理为 01–24 编号图片。旧图和清单现已退出公开展示，本地恢复清单保留尺寸与 SHA-256，见[清理记录](public-ui-1008v1.md)。

## Runtime acceptance boundaries

- 布局预览使用独立 UserDefaults 和演示 UsageStore，不连接 Hub、不读取真实凭据，不注册全局快捷键或启动更新检查。
- 不执行真实 CLI 派单、暖号、登录、Desktop 切号或飞书发送。现有业务逻辑与用户已经开启的后台自动化保持原样。
- 本地 Apple Silicon 构建使用 ad-hoc 签名，未进行 Apple 公证、Intel / Windows 打包、macOS 13 真机验收或长时间运行测试。
- 本次是本地 App 升级，不创建 GitHub tag 或公开二进制 Release。旧 App ZIP 备份分支与源码分支分别处理。

## Previous-version recovery

本地 `release-archives` 只保留上一版 `0905v2 / build 14` 的 App-only ZIP，完整性检查通过，可用于原位升级回滚。

更早的 `0905v1 / build 13` ZIP 已上传到 GitHub 的 `archive/app-backups` 分支（提交 `b938aa7`）。GitHub 返回的文件大小及 Git blob SHA 与本地一致后，才将本地旧 ZIP 移入废纸篓，可恢复。升级时临时保留的 build 14 解包副本也已移入废纸篓。

## Checksums

SHA-256：

| 产物 | 摘要 |
| --- | --- |
| 已安装 App 可执行文件 | `7f94ca1dda760061e0c90a88552721718dd0c8e14a6ab0cdf99d78c18ac5d679` |
| 上一版 `0905v2 / build 14` ZIP | `c8754e5b168ffd9fc7c6e64c0af955de5498b5ad8965160dbc7fed5123ae360d` |
| `05-next-settings-appearance-zh-dark@2x.png` | `50bc1c35056bd114e5251733bbbb19ad1df90b3c2774ba5ef8f91d2a2c1cec34` |
| `15-next-settings-appearance-en-light@2x.png` | `0492637d5b05d066a65b9dedcf7f3a4cdb06101e00efe03aeebf425a2d18cc93` |
| `07-next-settings-automation-zh-dark@2x.png` | `a1769c639890c055fa0db6740ad007e94c8d5c14f097249b2e475e148a8b277a` |
