# Service icon sources and rights

Verified on 2026-10-12. The two PNGs identify the notification services shown in this scripted promotional demo. They are required external inputs for source rendering and are not distributed as standalone images in the current Git layout or revised 1012v2 ZIP. That use does not assert a partnership, endorsement, or ownership of the service brands, and this notice does not grant permission to redistribute them.

## Verified source correspondence

At the source audit, the PNGs were byte-identical across the earlier motion project's `public/`, the Chinese scene's `ui/`, the English scene's `ui/`, the original Git copy, and the existing 1012v1 release ZIP. The retained source-baseline record also identifies the Chinese scene's files as the inputs copied into the English scene. The revised distribution excludes the standalone PNGs; these hashes document the expected external inputs and the historical copies.

| External input | Matching installed macOS application resource | PNG SHA-256 |
| --- | --- | --- |
| `ui/feishu.png` | Lark 8.0.6; bundle identifier `com.bytedance.macos.feishu`; declared icon resource `app.icns` | `41a1b460e85aa460e4d75f29d3c36fee2fe0f61389694ce97edef3955bd3d4ca` |
| `ui/wechat.png` | WeChat 4.1.13; bundle identifier `com.tencent.xinWeChat`; declared icon resource `AppIcon.icns` | `d2950dc500dd6b3309d3242aa2edc8b70e05eba889feb1ea8dd279fd587429c5` |

Verification decoded each retained PNG and the corresponding application's largest ICNS image to 1024 × 1024 RGBA, then compared every byte. Both comparisons were identical. The decoded RGBA SHA-256 values were:

- Lark/Feishu: `9e9257ac7d44ded04e28bb9bf0164e77162acd059d14bd44cb9dc0efce20eb99`.
- WeChat: `0c859ab5464af2d7ffef78ac064df82697c6012b1c14c197528184ece97a448e`.

This establishes correspondence to the installed application artwork. The historical extraction command, original download URL, and permission receipt were not retained. The PNG metadata contains image color/resolution information, not an origin URL or redistribution license. The [official Lark download page](https://www.larksuite.com/en_us/download) is a product reference; it is not a claimed download record for these PNGs.

## Official references and permission boundary

- [Feishu User Service Agreement](https://www.feishu.cn/terms), sections 5.1 and 10.1, reserves rights in service content and requires prior written consent for the listed copying, distribution, display, and other uses. It does not establish permission to bundle this application icon as a standalone PNG.
- [WeChat Branding Guidelines](https://newsroom.wechat.com/newsRooms/BrandingGuidelines) provides official logo downloads and requirements for appearance, clear space, minimum size, and prohibited alterations. A public logo download and those visual rules do not establish a general redistribution license for the retained app icon.
- [WeChat Terms of Service](https://www.wechat.com/en/service_terms.html#our_intellectual_property_rights), section 10, reserves intellectual property rights and requires prior written consent for uses of trademarks, product names, logos, and other brand features except where expressly provided. The page also distinguishes WeChat from Weixin users; it is not evidence of a grant for this package.

No license or written authorization for distributing these two standalone PNGs was found in the retained project records or the official pages checked. The repository's software license, including MIT where applicable, does not license these third-party icons or marks. Identifying the services in a demo describes the intended use; it is not proof that redistribution has been authorized.

For source rendering, follow [the external-input instructions](../ui/README.md) and provide matching files only from resources you are entitled to use. Do not treat extraction from an installed application, or a matching hash, as permission to use or redistribute its artwork. No replacement artwork was substituted: the approved video, source scene, and existing rendered images remain unchanged and still depict the original service marks. This notice does not establish permission for those depictions or for the historical 1012v1 archive.

[Origins and integrity](PROVENANCE.md) · [Package guide](../README.md)
