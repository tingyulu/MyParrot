# Testing

Four layers, ordered by how automatable they are:

| Layer | What | How to run |
| --- | --- | --- |
| 1. Self-test | 12 cases covering pure logic: file naming, sample queue (FIFO + ramped padding), resampling, stereo split, drain policy (no mid-speech zero gaps), gain/soft-limit, CAF→m4a export, SRT format, AEC (delay-align + NLMS, no-echo gate), device enumeration | `swift run MyParrotSelfTest` — Command Line Tools only, no Xcode needed |
| 2. Swift Testing | The same 12 cases via `@Test` wrappers (zero duplicated logic) | `swift test` — needs full Xcode toolchain |
| 3. Measured audio | Objective checks on real recordings with `ffmpeg astats` (per-channel RMS: is each track alive?), `silencedetect` at −90 dB (micro zero-gap fingerprint = padding clicks) | see commands below |
| 4. Manual | Anything needing real devices, TCC dialogs, GUI: hot-swap while recording, permission flows, Bluetooth behavior | a human and a Mac |

## Useful commands

```bash
# Per-channel health of a recording (L=them, R=you). A dead track shows RMS ≈ -inf.
ffmpeg -i rec.m4a -af astats=metadata=1 -f null - 2>&1 | grep -E "Channel|RMS level"

# Padding-click fingerprint: count micro all-zero gaps (≥1 ms at -90 dB) in the mic track.
# Healthy recordings: ~0 outside the very start/end.
ffmpeg -i rec.m4a -af "pan=mono|c0=c1,silencedetect=noise=-90dB:d=0.001" -f null - 2>&1 \
  | grep -c silence_duration
```

## The rule that matters most

**A green build does not prove audio works.** Layers 1–2 cover pure functions only. If you change capture, device handling, or transcription paths, run the real path (layer 3–4) before you trust it — and before you open a PR.
