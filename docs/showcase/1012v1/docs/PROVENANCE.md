# Origins and integrity

This package preserves the **English 1011v1** promotional scene and original video. The English scene was produced on the existing 48-second reference timeline. Packaging adds navigation, explanatory documents, and local playback/rendering tools; it does not alter the retained scene, images, soundtrack, cues, audio source, video, or existing production render frames.

[ORIGINALS.json](../ORIGINALS.json) records the 16 original source files, bytes, SHA-256 hashes, roles, and frame timestamps, including distribution status. Distributed originals were copied without modification and hash-checked against the local input files during packaging. The Git directory omits the MP4 binary, which is available as a separate [release download](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.0/AiGoodBro-English-1011v1.mp4) and in the release ZIP. The standalone service icons are required external render inputs and are omitted from the current Git layout and revised 1012v2 ZIP; see [asset notices](ASSET-NOTICES.md).

| Material | Source role |
| --- | --- |
| `scene-en-1011v1.html` | Existing English promotional scene, including measured title-width fitting. |
| `exports/AiGoodBro-English-1011v1.mp4` | Original final 48-second English export; no re-encoding. |
| `audio/reference-score-1011v1.wav` | Existing complete music and SFX track used by the English scene. |
| `score-en-1011v1.py` | Original procedural music/SFX source; NumPy, fixed seed 23. |
| `cues-en-1011v1.json` | Existing 150 BPM, 120-beat timeline and 70 sound event targets. |
| `assets/bro-halfbody.png` | Existing AiGoodBro half-body brand avatar. |
| `ui/feishu.png`, `ui/wechat.png` | Required external inputs, not distributed as standalone images. Verified correspondence to installed Lark/WeChat application resources is documented in [asset notices](ASSET-NOTICES.md), together with hashes and unconfirmed redistribution rights. |
| `frames/english-*.png` | Eight existing 1920 × 1440 production scene renders at recorded frame times. |

The video’s app-like interface is constructed from local HTML/CSS, generated SVG icons and quota rings, and a canvas for motion streaks. Most visual material is drawn by the scene; it does not depend on remote screenshots or fonts. The three external image files above are the only image assets referenced by that scene.

Font declarations are SF Pro Display, SF Pro Text, SF Mono, PingFang SC, system-ui, and Menlo. These fonts come from the rendering system; font files are not bundled or granted separate redistribution terms here. Fallbacks and rasterization can differ across platforms.

The full general workflow is available at [design-rules/apple-video-design/SKILL.md](../design-rules/apple-video-design/SKILL.md). Its name describes the production approach and does not imply an official Apple standard.

The package does not assign a new license to original brand imagery, third-party marks, or source files. The repository's software license does not grant rights to the Lark/Feishu or WeChat icons. Their source correspondence is verified; a license or written permission for distributing the standalone PNGs has not been established, so they are excluded from the current Git layout and revised ZIP. [Asset notices](ASSET-NOTICES.md) record the official terms checked. For source rendering, provide these files only from resources you are entitled to use, following [the external-input instructions](../ui/README.md). The unchanged video and scene renders still show their original service marks; excluding standalone inputs is not a new license for those depictions.

[Package guide](../README.md) · [Reproduction](REPRODUCE.md)
