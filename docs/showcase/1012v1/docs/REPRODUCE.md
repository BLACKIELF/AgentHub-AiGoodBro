# Reproduce the promotional scene

The complete release ZIP’s MP4 is the original encoded result. In a Git checkout, [download it separately](https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v2.5.0/AiGoodBro-English-1011v1.mp4) into `exports/AiGoodBro-English-1011v1.mp4` for the video player. [The exports guide](../exports/README.md) gives its hash. Rendering creates a separate candidate under `generated/`; it does not update the original video, scene, images, frames, or soundtrack.

## Preview

Opening [index.html](../index.html) directly is sufficient for the original MP4. For local preview with byte-range media delivery, run from the package directory:

```bash
node serve.mjs 8787
```

Open `http://127.0.0.1:8787/`, then use the chapter buttons or the editable-scene link. Stop the loopback server with Ctrl+C. The source scene exposes `window.sceneReady` and `window.renderAt(seconds)`; its Play/Pause control uses the included WAV as the clock. A numeric URL hash selects a source time, for example `scene-en-1011v1.html#24.8`.

## Existing runtime requirements

- Node.js with standard ES modules.
- An existing `playwright` or `playwright-core` installation and an existing Chromium/Chrome browser for screenshots and rendering.
- FFmpeg for a video render; FFprobe for inspection.
- Python 3 and NumPy only if regenerating the optional procedural score.

The tools perform no dependency or browser installation. If Playwright is already resolvable, the renderer uses it. Otherwise set `AGB_PLAYWRIGHT` to your existing module location. If using an existing system Chrome instead of Playwright’s existing browser, set `AGB_CHROME` to its executable. Optional executable overrides are `AGB_FFMPEG` and `AGB_PYTHON`.

```bash
export AGB_PLAYWRIGHT="path/to/existing/playwright"
export AGB_CHROME="path/to/existing/chrome-executable"
```

Supply your own paths; no original machine’s runtime path is embedded in this package. Resources are served from this package over loopback; the rendering page blocks nonlocal resource requests.

## Representative frames

```bash
node render.mjs stills
```

This renders the eight default frame numbers to `generated/stills/`, together with `render-check.json`. `--frames` and `--output` select another set. The renderer uses the original `renderAt(frame / 30)` entry and the original 1920 × 1440 viewport at DPR 1, like the source rendering chain.

```bash
node render.mjs stills --frames=213,462,744 --output=generated/selected-stills
```

The scene’s transforms and text widths depend on system fonts. Some styling in this original scene can retain the preceding seek’s state. The renderer therefore computes all original frames in sequence up to each requested frame, including frames it does not capture. This preserves the original scene’s style transitions without modifying its source. A still remains an inspection sample; full playback is needed to review complete motion.

## Short video

```bash
node render.mjs short
```

The default renders 13.60–16.40 s: the Feishu-to-WeChat handoff and message arrivals, 84 frames over 2.8 s. It samples the original scene at 30 fps and takes the same source-time interval from the original WAV. Output: `generated/notification-sample.mp4` and a companion JSON report.

```bash
node render.mjs short --start=7.6 --duration=1.6 --output=generated/reset-sample.mp4
```

Start and duration must align to 30 fps and remain within the 48-second timeline. An existing requested output causes the renderer to stop; choose another `generated/` output name for a subsequent run.

## Full candidate render

```bash
node render.mjs full
```

The full command samples frames 0–1439 at `frame / 30`, captures JPEG frames at quality 95, and encodes H.264 (CRF 16, medium preset, yuv420p) with AAC at 256 kb/s. It uses the original WAV and produces `generated/AiGoodBro-English-rerender.mp4`. It does not read a separate reference project. The original 48-second MP4 need not be rendered again to publish this package.

Font availability, Chrome version, OS rasterization, and FFmpeg can affect the rerender. The original source and bytes remain the reproducible starting point; this package does not claim a fresh render is byte-identical to the MP4. Validate any edited full candidate for layout, transitions, timing, decode, and listening before delivery.

## Optional audio regeneration

Prefer reusing [the original WAV](../audio/reference-score-1011v1.wav). To exercise the unmodified procedural audio source:

```bash
node render.mjs score
```

The original score code expects a JSON `dur` field; the exported cues file uses `duration`. The wrapper creates `generated/score-input.json` with both fields, then calls the original Python file to produce `generated/reference-score-rerender.wav`. The original code, cues, and WAV remain unchanged. NumPy’s random generator uses seed 23; cross-version audio bit equality is not guaranteed by these instructions.

## Inspect an encoded output

```bash
ffprobe -v error -show_streams -show_format -of json generated/notification-sample.mp4
ffmpeg -v error -i generated/notification-sample.mp4 -f null -
```

The public [validation note](VALIDATION.md) records the checks actually completed for this package. [Package guide](../README.md)
