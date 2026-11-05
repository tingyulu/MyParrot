# Testing

Four layers, ordered by how automatable they are, plus a UX performance gate that every build runs (below):

| Layer | What | How to run |
| --- | --- | --- |
| 1. Self-test | 135 `swift test` cases (115 in the `MyParrotSelfTest` executable) covering pure logic (0.5.5, 2026-11-05): file naming, sample queue (FIFO + ramped padding), resampling, stereo split, drain policy (no mid-speech zero gaps), gain/soft-limit, CAF→m4a export, SRT format, AEC (delay-align + NLMS, no-echo gate), device enumeration | `MYPARROT_NO_AFM=1 swift run MyParrotSelfTest` — works with Command Line Tools alone (the flag leaves out the Apple on-device model backend, whose macro plugin ships only with Xcode); building the app needs full Xcode |
| 2. Swift Testing | The same cases via `@Test` wrappers (zero duplicated logic), plus opt-in real-path suites (`MP_AFM_REAL=1`, `MP_WHISPER_REAL_FILE=<m4a>`) | `swift test` — needs full Xcode toolchain |
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

## UX performance gate (every build)

`scripts/dev/perf-gate.py` is the one-command check that typing notes while recording stays smooth (added in 0.5.4's follow-up, after the stutter fixed in 0.5.4 shipped without any automated guard):

```bash
bash scripts/dev/make-demo-audio.sh                  # once: two `say` voices → stereo demo dialogue (L=them, R=you)
python3 -I scripts/dev/perf-gate.py --engine apple    # or --engine whisper; --skip-build reuses the last isolated build
```

What it does: builds an isolated Debug bundle (bundle id suffix `.perfgate`, installed under `~/Library/Caches/MyParrot-perfgate/`, never touching `~/Applications`), launches it with a file replay source instead of the microphone (`MYPARROT_REPLAY`, so no audio permissions are needed), records 60 s while typing notes at 8 chars/s, and measures CPU, SwiftUI layout passes and main-thread stalls. It then injects a 300 ms block and a 120 Hz redraw storm as positive controls (the detectors must catch them), stops the recording and verifies per-channel RMS, duration, channel identity, the live transcript and the sidecar files, quits the app and compares against the baseline. Any red row makes it exit non-zero; known issues are labelled on the table, never used to relax a threshold. Needs the full Xcode toolchain and opens one app window per run.

## The rule that matters most

**A green build does not prove audio works.** Layers 1–2 cover pure functions only. If you change capture, device handling, or transcription paths, run the real path (layer 3–4) before you trust it — and before you open a PR.
