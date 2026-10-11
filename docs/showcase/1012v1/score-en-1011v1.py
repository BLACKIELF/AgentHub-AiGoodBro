"""AiGoodBro 1011v3 score v2 — 150 BPM, B minor / D major, produced from scratch in numpy.

Music: punchy kick + layered clap, humanized 16th hats, filter-enveloped saw bass, sidechained
pluck chords, wide supersaw pad, a memorable lead hook with ping-pong delay, risers, reverse swells,
snare-roll builds and big drops on every section downbeat. End card resolves and loops into bar 0.
SFX are tuned to the key and kept tasteful: titles get a light tap (not a boom), notifications get
distinct chimes (Feishu = marimba, WeChat = bubble), haptics are tight thumps.
"""
import json, sys, wave
import numpy as np

SR = 48000
rng = np.random.default_rng(23)
C = json.load(open(sys.argv[1]))
BPM = C['bpm']; BT = 60 / BPM; DUR = C['dur']; BEATS = C['beats']
N = int(round(DUR * SR))
drums = np.zeros((N, 2)); music = np.zeros((N, 2)); lead_bus = np.zeros((N, 2)); sfx = np.zeros((N, 2))
duck = np.ones(N)
T = lambda n: np.arange(n) / SR
m2f = lambda m: 440 * 2 ** ((m - 69) / 12)

def add(buf, t, s, g=1., pan=0.):
    i = int(round(t * SR)) % N
    if s.ndim == 1: s = np.stack([s * np.sqrt((1 - pan) / 2), s * np.sqrt((1 + pan) / 2)], 1)
    n = len(s); j = min(N, i + n); buf[i:j] += g * s[:j - i]
    if i + n > N: buf[:i + n - N] += g * s[j - i:]  # wrap → seamless loop
def lpf(x, fc, order=2):
    X = np.fft.rfft(x, axis=0); f = np.fft.rfftfreq(len(x), 1 / SR); g = 1 / np.sqrt(1 + (f / fc) ** (2 * order))
    return np.fft.irfft(X * (g[:, None] if x.ndim == 2 else g), n=len(x), axis=0)
def band(n, lo, hi, pink=False):
    X = np.fft.rfft(rng.standard_normal(n)); f = np.fft.rfftfreq(n, 1 / SR)
    g = 1 / np.sqrt(1 + (lo / np.maximum(f, 1)) ** 4) / np.sqrt(1 + (f / hi) ** 4)
    if pink: g = g / np.sqrt(np.maximum(f, 20) / 20)
    y = np.fft.irfft(X * g, n=n); return y / (np.abs(y).max() + 1e-9)
def env_ar(n, a=.003, r=.02):
    e = np.ones(n); na = max(1, int(a * SR)); nr = max(1, min(n - 1, int(r * SR)))
    e[:na] = np.linspace(0, 1, na); e[-nr:] *= np.linspace(1, 0, nr); return e
def saw(f, n, ph=0.): return 2 * ((f * T(n) + ph) % 1) - 1
def pan_sweep(x, a=-.8, b=.8):
    p = np.linspace(a, b, len(x)); return np.stack([x * np.sqrt((1 - p) / 2), x * np.sqrt((1 + p) / 2)], 1)

# ---------------- drums ----------------
def kick(big=False):
    n = int((.6 if big else .34) * SR); t = T(n); f = 44 + (170 if big else 150) * np.exp(-t * (26 if big else 34))
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * (3.2 if big else 7))
    click = np.zeros(n); k = int(.004 * SR); click[:k] = band(k, 2500, 12000) * np.linspace(1, 0, k)
    return np.tanh((body + .35 * click) * 1.7) * .95
KICK, KICKB = kick(), kick(True)
CLAPS = []
for v in range(4):
    n = int(.32 * SR); t = T(n); nb = band(n, 1100, 6000); s = np.zeros(n)
    for d in (0, .008, .017): o = int(d * SR); s[o:] += nb[:n - o] * np.exp(-t[:n - o] * 150)
    s += nb * np.exp(-t * 16) * .45; CLAPS.append(s * .8)
def snare(v=1.):
    n = int(.18 * SR); t = T(n)
    return (band(n, 1500, 9000) * np.exp(-t * 26) * .75 + np.sin(2 * np.pi * 190 * t) * np.exp(-t * 34) * .5) * v
HATS = [band(int(.05 * SR), 7500, 17000) * np.exp(-T(int(.05 * SR)) * 75) for _ in range(6)]
OHAT = band(int(.28 * SR), 6500, 16000) * np.exp(-T(int(.28 * SR)) * 9)
CRASH = band(int(2.2 * SR), 3000, 15000) * np.exp(-T(int(2.2 * SR)) * 2.2)

# ---------------- tonal (cached) ----------------
cache = {}
def bass(m, dur):
    k = ('b', m, round(dur, 3))
    if k in cache: return cache[k]
    n = int(dur * SR); t = T(n); f = m2f(m)
    x = .65 * saw(f, n) + .7 * np.sin(2 * np.pi * f * t) + .35 * np.sin(np.pi * f * t)
    e = np.exp(-t * 14); y = lpf(x, 240) * (1 - e) + lpf(x, 2200) * e
    y = np.tanh(y * 1.6) * env_ar(n, .002, .03); cache[k] = y; return y
def pluck(notes, dur=.9):
    k = ('p', tuple(notes), dur)
    if k in cache: return cache[k]
    n = int(dur * SR); t = T(n); y = np.zeros((n, 2))
    for i, m in enumerate(notes):
        for d, side in ((-.07, 0), (.07, 1)):
            y[:, side] += saw(m2f(m) * (1 + d / 100), n, rng.uniform())
    e = np.exp(-t * 10); y = lpf(y, 700) * (1 - e[:, None]) + lpf(y, 4500) * e[:, None]
    y *= (np.exp(-t * 3.2) * env_ar(n, .002, .05))[:, None]; y /= np.abs(y).max() + 1e-9; cache[k] = y; return y
def pad(notes, dur):
    k = ('pad', tuple(notes), round(dur, 3))
    if k in cache: return cache[k]
    n = int(dur * SR); y = np.zeros((n, 2))
    for m in notes:
        for v, d in enumerate((-.22, -.11, 0, .1, .21)):
            p = (v - 2) / 2.2; x = saw(m2f(m) * (1 + d / 100), n, rng.uniform())
            y[:, 0] += x * np.sqrt((1 - p) / 2); y[:, 1] += x * np.sqrt((1 + p) / 2)
    y = lpf(y, 1700) * env_ar(n, .25, .4)[:, None]; y /= np.abs(y).max() + 1e-9; cache[k] = y; return y
def lead(m, dur):
    k = ('l', m, round(dur, 3))
    if k in cache: return cache[k]
    n = int(dur * SR); t = T(n); f = m2f(m) * (1 + .0065 * np.sin(2 * np.pi * 5.6 * t) * np.clip((t - .12) / .1, 0, 1))
    ph = np.cumsum(f) / SR; x = .6 * (2 * (ph % 1) - 1) + .45 * np.sign(np.sin(2 * np.pi * ph))
    e = np.exp(-t * 7); y = lpf(x, 1400) * (1 - e) + lpf(x, 6000) * e
    y *= (.72 + .28 * np.exp(-t * 5)) * env_ar(n, .004, .06); cache[k] = y; return y
def bell(m, dur=1.8, a=1.):
    n = int(dur * SR); t = T(n); f = m2f(m)
    return sum(g * np.sin(2 * np.pi * f * r * t) * np.exp(-t * d) for r, g, d in [(1, 1, 2.4), (2.0, .35, 4), (2.76, .28, 5.5), (5.4, .12, 9)]) * env_ar(n, .001, .2) * a
def keys(notes, dur=2.4):
    n = int(dur * SR); t = T(n); y = np.zeros(n)
    for m in notes:
        f = m2f(m); y += sum((1 / k ** 1.5) * np.sin(2 * np.pi * f * k * t) * np.exp(-t * (1.6 + k * .8)) for k in range(1, 7))
    return y * env_ar(n, .003, .4) / (len(notes) + 1)

# ---------------- harmony & arrangement (beats) ----------------
CH = [[59, 62, 66], [55, 59, 62, 67], [57, 62, 66], [57, 61, 64]]       # Bm  G  D/A  A
BS = [47, 43, 38, 45]
HOOK = [[78, None, 81, 78, 76, None, 74, 76, 78, None, 83, 81, 78, 76, None, None],
        [74, None, 78, 74, 73, None, 71, 73, 74, 76, 78, None, 81, None, None, None]]
# (b0, b1, kick, clap, hats16, ohat, bass, pluck, pad, lead, arp, energy)
SEC = [(0, 4, 0, 0, 0, 0, 0, 0, 1, 0, 0, .5), (4, 16, 1, 1, 0, 1, 1, 1, 1, 0, 0, .85), (16, 26, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1.),
       (26, 48, 1, 1, 0, 1, 1, 0, 1, 0, 1, .85), (48, 66, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1.), (66, 78, 1, 1, 1, 1, 1, 1, 1, 0, 1, .95),
       (78, 92, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.), (92, BEATS, 0, 0, 0, 0, 0, 0, 1, 0, 0, .55)]
DROPS = [16, 48, 66, 78, 92]
BREAK = [(15.5, 16), (47.5, 48), (65.5, 66), (91.5, 92)]
brk = lambda b: any(a <= b < z for a, z in BREAK)
def kickhit(t, big=False):
    add(drums, t, KICKB if big else KICK, 1.0)
    i = int(round(t * SR)) % N; n = int(.24 * SR); c = 1 - .78 * np.exp(-T(n) * 13)
    j = min(N, i + n); duck[i:j] = np.minimum(duck[i:j], c[:j - i])
for (b0, b1, K, CP, H16, OH, BA, PL, PD, LD, AR, E) in SEC:
    b = b0
    while b < b1 - 1e-6:
        t = b * BT; bar = int(b // 4) % 4; ch = CH[bar]
        if not brk(b):
            if K and b % 1 == 0: kickhit(t, b in DROPS)
            if CP and b % 2 == 1: add(drums, t, CLAPS[int(b) % 4], .75 * E)
            if b % .5 == 0 or (H16 and b % .25 == 0):
                if b % .5 == 0 or H16:
                    v = (.9 if b % .5 == .25 else .55 if b % 1 == 0 else .75) * (.8 + .4 * rng.random()) * E
                    if K or b >= 4: add(drums, t, HATS[int(b * 4) % 6], v * .7, .3 if (b * 4) % 2 else -.3)
            if OH and b % 1 == .5: add(drums, t, OHAT, .32 * E, .15)
            if BA and b % .5 == 0:
                m = BS[bar] + (12 if b % 1 == .5 else 0); add(music, t, bass(m, BT * .48), .55 * E)
            if PL and b % 1 == .5: add(music, t, pluck([n + 12 for n in ch]), .32 * E)
            if AR and b % .25 == 0:
                seq = ch + [ch[0] + 12]; m = seq[int(b * 4) % len(seq)] + 24
                add(music, t, bell(m, .35, .5), .12 * E, .45 * np.sin(b * 2.1))
            if LD and b % .5 == 0:
                ph = HOOK[(int(b // 8)) % 2]; step = int(((b % 8) / .5)); m = ph[step]
                if m is not None:
                    k = 1
                    while step + k < 16 and ph[step + k] is None and k < 3: k += 1
                    add(lead_bus, t, lead(m + (12 if b >= 78 else 0), BT * .5 * k * .92), .28 * E, .1)
        if PD and b % 4 == 0: add(music, t, pad([n for n in ch] + [ch[0] - 12], 4 * BT + .3), .22 * E)
        b = round(b + .25, 4)
# builds, drops, end card
for d in DROPS:
    add(sfx, d * BT, CRASH, .5)
    n = int(.5 * SR); sw = band(n, 2000, 14000, True) * np.linspace(0, 1, n) ** 3; add(sfx, d * BT - .5, sw, .55)
for b0, b1 in [(14, 15.5), (46, 47.5), (90, 91.5)]:
    b = b0
    while b < b1: add(drums, b * BT, snare(.35 + .65 * (b - b0) / (b1 - b0)), .7); b += .25 if b < b1 - 1 else .125
for i, ch in enumerate([CH[1], CH[2], CH[3], CH[0], CH[1], CH[2], CH[3]]):
    add(music, (93 + i * 4) * BT, keys([n + 12 for n in ch], 4 * BT + 1), .9)
for i, b in enumerate(range(92, 116, 4)): kickhit(b * BT); add(drums, b * BT, OHAT, .2)
# filter sweep on the intro (opens over 4 beats) and gentle fade at the very end
iI = int(4 * BT * SR); ramp = np.linspace(0, 1, iI) ** 2
music[:iI] = lpf(music[:iI], 500) * (1 - ramp[:, None]) + music[:iI] * ramp[:, None]

# ---------------- SFX ----------------
def whoosh(d, lo=400, hi=8000, a=-.7, b=.7):
    n = int(d * SR); u = np.linspace(0, 1, n); x = band(n, lo, hi, True) * np.sin(np.pi * u) ** 2.2
    return pan_sweep(x, a, b)
def tap():
    n = int(.06 * SR); t = T(n); return band(n, 1800, 9000) * np.exp(-t * 90) * .35 + np.sin(2 * np.pi * m2f(86) * t) * np.exp(-t * 60) * .25
def boom():
    n = int(1.6 * SR); t = T(n); f = 38 + 60 * np.exp(-t * 14)
    return np.tanh(np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 2.6) * 1.4) * .9 + band(n, 300, 5000) * np.exp(-t * 8) * .25
def tick(i):
    n = int(.16 * SR); t = T(n); f = 1500 + i * 260
    return (np.sin(2 * np.pi * f * t) * np.exp(-t * 55) + .5 * np.sin(2 * np.pi * 1.5 * f * t) * np.exp(-t * 80)) * .8
def marimba(m):
    n = int(.9 * SR); t = T(n); f = m2f(m)
    return (np.sin(2 * np.pi * f * t) * np.exp(-t * 7) + .3 * np.sin(2 * np.pi * 4 * f * t) * np.exp(-t * 28) + .15 * np.sin(2 * np.pi * 10 * f * t) * np.exp(-t * 60)) * env_ar(n, .001, .1)
def bubble(m):
    n = int(.6 * SR); t = T(n); f0 = m2f(m); f = f0 * (.55 + .45 * (1 - np.exp(-t * 90)))
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 9) * env_ar(n, .001, .08)
def haptic():
    n = int(.07 * SR); t = T(n); s = np.sin(2 * np.pi * 120 * t) * np.exp(-t * 70)
    s[:int(.002 * SR)] += band(int(.002 * SR), 3000, 12000) * .4; return np.tanh(s * 2) * .8
def flick():
    n = int(.12 * SR); t = T(n); return band(n, 2200, 8000) * np.exp(-t * 45) * .5
def drop():
    n = int(.35 * SR); t = T(n); f = 520 + 1100 * np.exp(-t * 40)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 11) * .6
def plane():
    d = 1.4; n = int(d * SR); t = T(n); u = t / d
    w = whoosh(d, 900, 9000, -.9, .9); wh = np.sin(2 * np.pi * np.cumsum(900 + 1300 * u) / SR) * np.sin(np.pi * u) ** 2 * .12
    return w + pan_sweep(wh, -.9, .9)
def data(d):
    n = int(d * SR); s = np.zeros(n)
    for k in np.arange(0, d, BT / 4):
        i = int(k * SR); m = min(n - i, int(.025 * SR)); tt = T(m); s[i:i + m] += np.sin(2 * np.pi * (2600 + 500 * rng.integers(0, 3)) * tt) * np.exp(-tt * 140) * .2
    return s
def chime():
    return sum(bell(m, 3.2, a) for m, a in [(86, .6), (90, .45), (93, .35), (98, .2)])
FEISHU = [81, 85, 88]; WX = [76, 79, 83]
MAP = {
    'hit': lambda c: (tap(), 0, .55, 0), 'impact_big': lambda c: (boom(), 0, .9, 0),
    'whoosh': lambda c: (whoosh(.55), .32, .55, 0), 'whoosh_big': lambda c: (whoosh(.95, 250, 7000), .55, .8, 0),
    'tick': lambda c: (tick(c['n']), 0, .7, 0), 'ping': lambda c: (marimba(FEISHU[c['n'] % 3]), 0, .55, .25),
    'ping2': lambda c: (bubble(WX[c['n'] % 3]), 0, .6, -.25), 'haptic': lambda c: (haptic(), 0, .8, .3),
    'card': lambda c: (flick(), 0, .6, (c['n'] - 1) * .3), 'drop': lambda c: (drop(), 0, .7, 0),
    'plane': lambda c: (plane(), 0, .75, 0), 'data': lambda c: (data(c['d']), 0, .5, .2), 'chime': lambda c: (chime(), 0, .75, 0),
}
for c in C['cues']:
    c.setdefault('n', 0); c.setdefault('d', 1.0)
    if c['k'] not in MAP: continue
    s, pre, g, pan = MAP[c['k']](c); add(sfx, max(0, c['t'] - pre), s, g, pan)

# ---------------- FX & mix ----------------
def delay(x, beats, fb=.35, n=4):
    y = x.copy(); d = int(beats * BT * SR)
    for k in range(1, n + 1):
        sh = np.zeros_like(x); sh[d * k:] = x[:-d * k] * fb ** k
        if k % 2: sh = sh[:, ::-1]
        y += sh
    return y
def reverb(x, secs, mix, damp):
    n = int(secs * SR); t = T(n)
    ir = np.stack([rng.standard_normal(n), rng.standard_normal(n)], 1) * np.exp(-t * 6.5 / secs)[:, None]
    ir = lpf(ir, damp); ir[:int(.01 * SR)] = 0; ir /= np.sqrt((ir ** 2).sum(0)).max() * 3
    F = 1 << int(np.ceil(np.log2(len(x) + n))); y = np.fft.irfft(np.fft.rfft(x, F, axis=0) * np.fft.rfft(ir, F, axis=0), F, axis=0)
    out = x * (1 - mix); out += y[:len(x)] * mix; out[:n] += y[len(x):len(x) + n] * mix; return out
lead_bus = delay(lead_bus, .75, .32)
music = (music + lead_bus) * (duck * .85 + .15)[:, None]
music = reverb(music, 2.0, .22, 6000); drums = reverb(drums, .7, .08, 8000); sfx = reverb(sfx, 1.4, .18, 7000)
rms = lambda x: np.sqrt((x ** 2).mean()) + 1e-9
drums *= .13 / rms(drums); music *= .10 / rms(music); sfx *= .62 / (np.abs(sfx).max() + 1e-9)
mix = drums + music + sfx
# stereo width on music only (mid/side)
mid = (mix[:, 0] + mix[:, 1]) / 2; side = (mix[:, 0] - mix[:, 1]) / 2 * 1.15; mix = np.stack([mid + side, mid - side], 1)
mix = np.tanh(mix * 1.25) / np.tanh(1.25); mix *= .96 / np.abs(mix).max()
pcm = (np.clip(mix, -1, 1) * (2 ** 23 - 1)).astype(np.int32); b = np.zeros((N, 2, 3), np.uint8)
for k in range(3): b[..., k] = (pcm >> (8 * k)) & 0xFF
with wave.open(sys.argv[2], 'wb') as w: w.setnchannels(2); w.setsampwidth(3); w.setframerate(SR); w.writeframes(b.tobytes())
print(json.dumps({'out': sys.argv[2], 'dur': DUR, 'bpm': BPM, 'cues': len(C['cues'])}))
