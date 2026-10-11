# Reusable product video rules

This folder contains general rules for original product videos, reference reproduction, localization, motion study, audio and visual checks, and reproducible handoff. The main rules are in Chinese. Start with [SKILL.md](SKILL.md), or read the [Chinese usage guide](使用说明.md).

- [Frame and rhythm checks](references/fidelity.md)
- [Localization and text layout](references/localization.md)
- [Verifying motion from source](references/motion-learning.md)
- [Optional frame comparison tool](scripts/compare_video.py)

Keep this folder structure intact so relative links continue to work. The optional comparison tool requires existing Python 3, NumPy, FFmpeg and ffprobe:

```bash
python3 scripts/compare_video.py --help
```

The folder can be read directly or used as an optional Codex Skill installation source. It does not install, sync or overwrite an active Skill. Check existing rules and review differences before any separately authorized installation or overwrite.

“Apple-style” describes a creative direction. This package is not official Apple guidance and makes no claim of affiliation, authorization or certification.

Image, avatar or brand asset replacements require explicit user permission and the applicable rights-holder permissions. This package grants no rights to use, replace or redistribute media.
