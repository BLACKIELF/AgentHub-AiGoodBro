# Validation scope · 1012v2

These are local package checks performed on **2026-10-12**. The original 1012v1 playback and scene-render evidence below used all original local inputs. Version 1012v2 retains the same video, scene and frames, fixes the comparison tool, and omits two standalone service icons; a new HTML render requires those authorized local inputs. These checks do not test an application backend, live quotas, notification delivery, proxy operation, or physical haptics.

## Original material

- All **14 retained original files** match their packaging input SHA-256 and byte sizes, including the MP4, scene, cues, score source, WAV, AiGoodBro avatar, and eight render frames. The two service-icon inputs are listed separately as required but not distributed in [ORIGINALS.json](../ORIGINALS.json).
- All eight retained frames are the existing **1920 × 1440** files, copied without modification. Their timestamps are listed in [ORIGINALS.json](../ORIGINALS.json).
- The original MP4 reports **48.000 s**, **1920 × 1440**, **30/1 fps**, **1440 video frames**, **H.264 video**, and **48 kHz stereo AAC**. Full FFmpeg decode completed with **exit code 0 and no error output**.

## Player

The package’s native HTML video player was exercised in local Chrome **154.0.8037.98**. Normal-speed playback reached the 48-second end in **48.052 seconds**, with **0 reported dropped video frames**, no media error, and no page script or failed-resource errors. The test was muted and is technical playback evidence, not a subjective listening review.

Seven chapter buttons sought to their exact target times: **6.4, 10.4, 19.2, 22.4, 26.4, 31.2, and 36.8 seconds**. The loopback server returned **HTTP 206** and the requested **128 bytes** for a video byte-range request.

The complete ZIP contains the MP4. A Git checkout needs the separately downloaded release video in the documented `exports/` path; this difference is intentional and does not change the original file. A simulated missing-video HTTP 404 displayed the download notice and release links, without an automatic remote download. The `#t=15.4` player seek, editable-scene loading at `#15.4`, and scene Play/Pause controls also passed.

## Portable render entry

The original 1012v1 renderer checks loaded the unmodified scene and all three local image inputs. The scene’s duration, BPM, beats, and all **70 cues** matched the original cues JSON. It made no external page-resource requests and reported no scene script or missing-resource errors. These historical checks do not imply that the current distribution includes the two standalone service icons.

- **Eight representative frames** were rendered using the original `renderAt(frame / 30)` entry and a 1920 × 1440, DPR 1 viewport.
- The notification handoff at **13.60–16.40 s** was rendered as a separate **2.800 s / 84-frame** H.264/AAC sample with the same source-time interval of the original WAV. Its full decode completed with exit code 0 and no errors.
- The renderer computes the original source frames in sequence before a requested capture. This prevents an earlier seek’s hover styling from leaking into a later sample, while leaving the scene and timeline unchanged.

The new render samples are verification outputs, not replacements for the original showcase frames or MP4. Comparison with the retained stills did not produce full pixel equality across all samples, so no such claim is made. System fonts, browser composition, rasterization, and encoding remain relevant to another machine’s results. No new full 48-second candidate render was needed or performed for packaging.

## Optional score generation

The original procedural score source ran with the wrapper’s `duration` → `dur` input-field adaptation and generated a 48 kHz stereo WAV. Its decoded PCM **did not match** the retained original WAV in this environment. The generated result is a separate reproduction candidate; playback and video rendering continue to use the unchanged original WAV. The original audio source, cue file, and WAV bytes remain preserved.

## Public package checks

The package includes local sources and deliberate release-download links. Retained images were visually inspected; no image was changed. Text scans found no original machine paths, email addresses, credential assignments, or private-key headers in the distributed text files. Relative documentation links resolve inside the package; the scene's two external service-icon inputs are explicitly documented exceptions. Generated samples and local QA outputs are excluded from the distributed package.

The repaired comparison tool passed **7 synthetic test methods covering 32 scenarios**, including direct, symlink and hard-link output aliases, late alias creation, path-redacted success/failure reports, and unchanged media inputs. The 1012v2 renderer rejects missing or mismatched required service-icon inputs before browser launch and output creation. Original MP4 playback does not depend on those separate PNGs.

The download URLs identify the intended release assets. Package checks do not by themselves confirm that the release was uploaded or published.

[Reproduction instructions](REPRODUCE.md) · [Original-file manifest](../ORIGINALS.json) · [Package guide](../README.md)
