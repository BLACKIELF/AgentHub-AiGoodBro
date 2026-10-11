# Timeline · English 1011v1

The source uses **150 BPM** (`60 / 150 = 0.4 s/beat`), **120 beats**, and **48 seconds**. Output is **30 fps** (`frame = seconds × 30`). Intervals are source boundaries and generally include the start while excluding the end. A fractional frame boundary is first displayed at the next actual 30 fps frame.

| Seconds | Beats | Source segment | Main behavior |
| --- | --- | --- | --- |
| 0.00–3.04 | 0–7.6 | Opening | App window enters; brand title appears at 1.60 s and leaves by 3.00 s. |
| 3.04–6.40 | 7.6–16 | Home skim and reset handoff | One-subject-per-beat camera targets at 3.20–5.20 s; the camera returns to the full window by 5.84 s. |
| 6.40–10.40 | 16–26 | Reset alerts | Banner → notice → countdown → confirmation → banner. |
| 10.40–19.20 | 26–48 | Notifications and planning titles | Feishu and WeChat panels, then two planning lines. |
| 19.20–22.40 | 48–56 | Usage stats | KPI strip → heatmap → chart → account grid. |
| 22.40–26.40 | 56–66 | Edge sidebar | Rail, quota rings, cursor, five feedback events. |
| 26.40–31.20 | 66–78 | Local proxy presentation | Rail scale change and anchored status popover. |
| 31.20–34.40 | 78–86 | Multiple-account view | Three card camera targets, then a full-window return. |
| 34.40–36.80 | 86–92 | Montage | Six one-beat titles summarize the existing segments. |
| 36.80–48.00 | 92–120 | Closing and loop transition | Four fixed lines arrive, leave, and the scene approaches its opening pose. |

## Exact events

| Event | Beat | Seconds | Frame boundary |
| --- | --- | --- | --- |
| Large reset digit 3 | 19 | 7.60 | 228 |
| Large reset digit 2 | 20 | 8.00 | 240 |
| Large reset digit 1 | 21 | 8.40 | 252 |
| Scripted reset confirmation and count change | 22 | 8.80 | 264 |
| Snap back to full banner | 22.35 | 8.94 | 268.2 |
| Feishu first, second, third card start | 29 / 30.5 / 32 | 11.60 / 12.20 / 12.80 | 348 / 366 / 384 |
| Feishu begins moving left | 34 | 13.60 | 408 |
| WeChat first, second, third message start | 36.5 / 38 / 39.5 | 14.60 / 15.20 / 15.80 | 438 / 456 / 474 |
| Both chat panels hidden | 42 | 16.80 | 504 |
| Five sidebar feedback cues | 60 / 61 / 62 / 63 / 64 | 24.00 / 24.40 / 24.80 / 25.20 / 25.60 | 720 / 732 / 744 / 756 / 768 |
| Popover becomes visible | 67 | 26.80 | 804 |
| Popover scale transition starts / ends | 67.2 / 68.4 | 26.88 / 27.36 | 806.4 / 820.8 |
| Account camera targets | 79 / 81 / 83 | 31.60 / 32.40 / 33.20 | 948 / 972 / 996 |
| Closing line starts | 94 / 95.5 / 97 / 98.5 | 37.60 / 38.20 / 38.80 / 39.40 | 1128 / 1146 / 1164 / 1182 |
| Closing chime | 103 | 41.20 | 1236 |
| Closing titles begin fading / become hidden | — / 116 | 46.10 / 46.40 | 1383 / 1392 |
| Final drop cue | 119.2 | 47.68 | 1430.4 |
| End | 120 | 48.00 | 1440 (exclusive) |

The 70 audio cues are stored as event target times in [cues-en-1011v1.json](../cues-en-1011v1.json). Audio-source functions may start a whoosh or swell before the target event; cue time is not always the first nonzero audio sample.

The timing above is taken from `K`, `T()` calls, `scene()`, `chats()`, and `dock()` in the [English scene](../scene-en-1011v1.html), rather than estimated from screenshots. [Interface forms](INTERFACE-FORMS.md) · [Package guide](../README.md)
