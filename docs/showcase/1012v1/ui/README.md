# Required local service icons

`feishu.png` and `wechat.png` are external rendering inputs and are not distributed as standalone files in the current Git showcase or **1012v2** ZIP. The unmodified HTML still names them so it can be rendered using locally supplied, authorized resources. The original MP4 and retained frames remain available without these files.

Supply these exact original PNGs only when you have the right to use the underlying official application resources. Their recorded hashes identify the source inputs; they do not grant redistribution rights. Official origins and applicable terms are recorded in [asset notices](../docs/ASSET-NOTICES.md).

| Local filename | SHA-256 | Bytes |
|---|---|---|
| `feishu.png` | `41a1b460e85aa460e4d75f29d3c36fee2fe0f61389694ce97edef3955bd3d4ca` | 130,162 |
| `wechat.png` | `d2950dc500dd6b3309d3242aa2edc8b70e05eba889feb1ea8dd279fd587429c5` | 171,699 |

Before launching a browser or writing frames, `render.mjs` rejects a missing file or a hash mismatch with a clear message. It does not download an icon, replace it with another logo, or edit the original scene. Normal MP4 playback does not call this renderer.

中文：两张独立服务图标不随当前 Git 目录或 1012v2 ZIP 分发。只有在具有合法使用权时，才从自己的本机资源提供上述原图；原片播放不需要补图。哈希用于识别原输入，不是许可。缺图或图不匹配时，渲染入口会明确停止，不自动下载或替换。
