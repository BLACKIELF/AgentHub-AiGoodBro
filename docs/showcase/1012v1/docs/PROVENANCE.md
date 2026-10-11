# Origins and integrity

This package preserves the **English 1011v1** promotional scene and original video. The English scene was produced on the existing 48-second reference timeline. Packaging adds navigation, explanatory documents, and local playback/rendering tools; it does not alter the retained scene, images, soundtrack, cues, audio source, video, or existing production render frames.

[ORIGINALS.json](../ORIGINALS.json) lists the complete release package’s 16 retained original files, bytes, SHA-256 hashes, roles, and frame timestamps. All retained originals were copied without modification and hash-checked against the local input files during packaging. The Git directory omits the MP4 binary, which is available as a separate [release download](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.0/AiGoodBro-English-1011v1.mp4) and in the complete ZIP.

| Material | Source role |
| --- | --- |
| `scene-en-1011v1.html` | Existing English promotional scene, including measured title-width fitting. |
| `exports/AiGoodBro-English-1011v1.mp4` | Original final 48-second English export; no re-encoding. |
| `audio/reference-score-1011v1.wav` | Existing complete music and SFX track used by the English scene. |
| `score-en-1011v1.py` | Original procedural music/SFX source; NumPy, fixed seed 23. |
| `cues-en-1011v1.json` | Existing 150 BPM, 120-beat timeline and 70 sound event targets. |
| `assets/bro-halfbody.png` | Existing AiGoodBro half-body brand avatar. |
| `ui/feishu.png`, `ui/wechat.png` | Existing third-party service icon images used in the scene. |
| `frames/english-*.png` | Eight existing 1920 × 1440 production scene renders at recorded frame times. |

The video’s app-like interface is constructed from local HTML/CSS, generated SVG icons and quota rings, and a canvas for motion streaks. Most visual material is drawn by the scene; it does not depend on remote screenshots or fonts. The three external image files above are the only image assets referenced by that scene.

Font declarations are SF Pro Display, SF Pro Text, SF Mono, PingFang SC, system-ui, and Menlo. These fonts come from the rendering system; font files are not bundled or granted separate redistribution terms here. Fallbacks and rasterization can differ across platforms.

The full general workflow is available at [design-rules/apple-video-design/SKILL.md](../design-rules/apple-video-design/SKILL.md). Its name describes the production approach and does not imply an official Apple standard.

The package does not assign a new license to original brand imagery, third-party marks, or source files. Redistribution and reuse follow applicable rights and any license established by the destination repository owner.

[Package guide](../README.md) · [Reproduction](REPRODUCE.md)
