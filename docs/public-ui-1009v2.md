# 实机界面来源 · 1009v2

核验日期：2026-10-09（Asia/Shanghai）。本记录服务于 AiGoodBro 2.4 · 1009v2 的中英文 README；[1008v1 历史清理记录](public-ui-1008v1.md)原样保留。

## 版本与来源

README 总览复用已公开的 **2.3.0 (137)** 主界面长图，账号与用量章节使用由该原图裁出的独立功能图，并保留用户提供的侧栏原图；新增六张登录、引导与设置图来自已安装的 **2.3.0 (139)**。139 所示设置在 2.4 中沿用相同呈现；137 主界面图仅用于说明总览、账号与用量区域，不作为 2.4 新增布局的验证图。

新增六图的实际格式为 JPEG，已仅将交付文件扩展名改为 `.jpg`；复用的两图为 PNG。这八张来源图均保留原始字节。另有两张经用户明确授权、从 137 首页图裁出的无损 PNG，裁剪区域内每个像素均与原图一致；未重绘、添加测试账号、合成额度或修改数值。**2.4.0 (141) 尚未安装**；这些图片不作为 141 覆盖安装、正常启动或真实提供方调用验收。图片中的 Token、额度、失败提示和连接状态只代表拍摄时刻。35+ 工具 Token 追踪、28+ 提供方额度检测是固定上游的支持范围，不代表本机全部连接。

## 新增原始 JPEG

以下六图均于 **2026-10-09** 从本机 **2.3.0 (139)** 采集。采集工具返回 JPEG 字节，但原始文件误用 `.png` 后缀；本次仅修正交付文件名，原始采集文件保持不变。使用 Pillow 仅读取实际格式与尺寸，未调用图像保存或转换。机器可读来源、原始采集文件名、格式、尺寸、字节数及逐图说明见 [manifest.json](images/1009v2/manifest.json)。

| 交付图片 | 原始采集文件名 | 实际格式与尺寸 | SHA256 |
|---|---|---|---|
| [reset-auto.jpg](images/1009v2/reset-auto.jpg) | `reset-auto.png` | JPEG · 940 × 1200 | `d3b4fe3a76fd04280e2a251504f87d0ff88b8d865949eb0cfad92596ae3b6f07` |
| [claude-login.jpg](images/1009v2/claude-login.jpg) | `claude-login.png` | JPEG · 1120 × 950 | `abd2ff298c969ea2737267d718a46e04c231b8f6110403cb6e029df46bd3b10e` |
| [guide.jpg](images/1009v2/guide.jpg) | `guide.png` | JPEG · 1800 × 1360 | `d1a739367345e9323cb64917408adccd7b17a61ba3e38e09c8718780eb838c4d` |
| [notifications-guide.jpg](images/1009v2/notifications-guide.jpg) | `notifications-guide.png` | JPEG · 1800 × 1360 | `413b7962a7716ab9f22f26194c37ca5d292faedbb545d5d6564c3817a1f2f1af` |
| [appearance-settings.jpg](images/1009v2/appearance-settings.jpg) | `appearance-settings.png` | JPEG · 1560 × 1280 | `dcc829bf15b33246b17bf17b6df1f0bf7e31455ecd841eeb1c1015920fe2716b` |
| [edge-dock-settings.jpg](images/1009v2/edge-dock-settings.jpg) | `edge-dock-settings.png` | JPEG · 1560 × 1280 | `ecf7c840d02e41e7ba2d694165834a89d52e235be62cac78bcb2430b26706410` |

## 复用的已公开原图

| 图片 | 版本依据 | SHA256 |
|---|---|---|
| [home-live.png](images/1009v1/home-live.png) | 137 | `e844d487e996856daab62f1e297990a6b7d8d7f5b7600982310fc2f39c9c9ee2` |
| [proxy-status-edge-dock.png](images/1009v1/proxy-status-edge-dock.png) | 未显示版本 | `1ed2210647d0cd532674b0efd2cd7bda92f0d0662bd3e9d7af800b16922917a2` |

137 主界面图于 2026-10-09 使用 App 的“保存主界面长截图”导出，随后读取已安装 App 的版本核实为 2.3.0 (137)。用户提供的侧栏局部图未显示版本编号，不能绑定到 139 或 141；其拍摄日期未独立确认。两图已实际识别为 PNG，尺寸分别为 2880 × 2906 与 714 × 1830，保留原路径及校验值，详情见 [1008v1 来源记录](public-ui-1008v1.md)。

## 经授权的独立功能裁图

2026-10-09 经用户明确授权，使用 Pillow 的 `Image.crop` 从已公开 137 首页原图截取完整账号区及用量区，保存为无损 PNG；未缩放、重绘、遮盖、标注或改变数值。已查看两张裁图，并对解码后的 RGBA 像素逐字节比较，均与原图对应区域完全一致。总览继续保留完整原图。

来源：[home-live.png](images/1009v1/home-live.png)，2880 × 2906，SHA256：`e844d487e996856daab62f1e297990a6b7d8d7f5b7600982310fc2f39c9c9ee2`。坐标按原图像素计算，左上角为原点，格式为 `[left, top, right, bottom]`，右、下边界不包含在裁图内。

| 图片 | 原图裁剪坐标 | 尺寸 | 裁图 SHA256 |
|---|---|---|---|
| [accounts-home-137-crop.png](images/1009v2/accounts-home-137-crop.png) | `156, 1371, 2852, 2307` | 2696 × 936 | `d87448f0b3b1e209bdcdfd1b745db76ca7c9bd3f83d38c20021051608f3fc9ed` |
| [usage-home-137-crop.png](images/1009v2/usage-home-137-crop.png) | `156, 740, 2852, 1368` | 2696 × 628 | `495089bdca34ee4afdddec8c96b863a502724a3d47d99331b83e9212069f5df0` |

坐标、来源哈希、裁图哈希和像素校验结果同时保存在 [manifest.json](images/1009v2/manifest.json) 的 `croppedImages` 中。两张图仅改取景范围，账号及统计仍为 137 原图拍摄时状态，不作为 141 运行验收。

## 读图边界

- 总览保留已公开 137 完整主界面图；Codex 账号与用量章节分别使用该原图的独立裁图。裁图所含账号与数值均已存在于公开原图，不新增公开含账号别名与余额的 139 卡片图。
- Claude 图只展示真实官方 CLI 登录与保存入口；没有用测试账号额度图替代真实登录或额度验收。
- Kimi 及其他工具用 139 工具连接引导配图，其中 Kimi 显示“已发现认证配置”；这不证明 Kimi 额度读取成功。
- 重置卡图只含别名、开关和提前时间，无邮箱、密钥或余额。25 分钟为本机自定义值，产品默认仍为 30 分钟；已开启数量不证明真实自动兑换。
- 通知图显示微信等待会话、飞书本机授权就绪但投递待验证；连接和开关不证明手机收件。
- 主题图展示真实“显示与图标”设置及当前默认配色，不声称拍齐九套主题。侧栏设置图不验证全局快捷键、触控板触感或真实反代请求。

## 本轮取舍

用户要求重点功能单独截图；本轮已按功能整理现有六张 139 独立实拍原图。补拍工具连续失败，重置后获取应用仍报告 `kernel exited`，因此未产生新的 141 截图；本轮只使用已有且已授权的真实截图完成配图。用户随后明确授权从已公开首页原图裁出账号和用量独立图，现已完成并逐像素验证；两图来源仍为 137，不是新拍的 141 界面。未新增主界面、新功能窗口、Kimi 额度页或反代设置面板截图；新功能由文字及相应功能章节说明，反代使用已公开的状态原图。README 不保留不存在的图片引用，也不把引导图说成额度页或新功能窗口。

未采用含错误 toast 的初始账号卡片图；新账号卡片图含别名与余额，本轮不加入公开交付；Codex 专用页窄窗口列表的反代／调度／优先／最后使用控件存在挤压，按用户决定留待下一版修正，不采用该图；初始反代设置图带未保存草稿警告，也不采用。未使用合成预览、测试额度图或重绘图片替补。

## 发布候选验证

最终 2.4.0 (141) / 1009v2 本地候选已通过 35 组原生自测（Carbon 冲突集成按验证环境设置跳过）、Desktop / 反代 / Companion / Engine 四项资源验证与完整应用递归签名检查。DMG 与 ZIP 均通过完整性、2,144 项文件树、权限、链接及严格递归签名核验；本轮校验值已与最终包文件重新对齐。Desktop 与 Engine 均包含 Grok 提示词标题修复。签名为 ad-hoc，未 Apple 公证；141 未安装、未正常启动验收，截图来源仍为上述 137 / 139 或未显示版本的原图。本地 Go race 证据为网关聚焦检查；全量结果以对应提交的 GitHub CI 为准，见 [PR #31](https://github.com/BLACKIELF/AgentHub-AiGoodBro/pull/31) 与 [CI 运行记录](https://github.com/BLACKIELF/AgentHub-AiGoodBro/actions/workflows/ci.yml)。本轮用户反馈反代再次异常需重启恢复，原因仍在排查；本次不据此宣称永久解决或保证真实反代稳定性。详细边界与最终安装包 SHA256 / 字节数见 [2.4 发布说明](release-notes-v2.4.0.md)。

[中文 README](../README.md) · [English README](../README.en.md)
