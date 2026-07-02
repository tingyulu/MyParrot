# 🦜 MyParrot

**Bot-free meeting recorder + transcriber for macOS.** Records both sides of your online meeting into one stereo file — the remote party on the **left** channel, you on the **right** — so every line is speaker-tagged for free. No diarization model, no meeting bot joining your call, nothing leaves your Mac.

[繁體中文說明 →](README.zh-TW.md)

## Why stereo-split?

"Who said what" is the hard part of meeting transcription. MyParrot sidesteps it with physics instead of ML: the other side comes from a system-audio tap, you come from the microphone, and each gets its own channel. Split the file, transcribe each track, interleave by time — perfect speaker attribution, fully offline.

## Features

- **The other side** — Core Audio **Process Tap** (macOS 14.4+): captures system audio with no driver, no kernel extension, no virtual audio device
- **You** — AVAudioEngine microphone capture that **survives device/route changes mid-recording** (auto-heal on configuration change + a liveness watchdog; hot-swap mics without stopping — the file stays continuous)
- **Live transcript** while recording — macOS 26 SpeechAnalyzer (long-form streaming), automatic fallback to SFSpeechRecognizer on older systems
- **Transcribe past recordings** → `.txt` + timestamped, speaker-prefixed `.srt`
- **Offline echo cancellation** (optional, non-destructive — writes `*_aec.m4a`, never touches the original)
- Auto CAF→m4a conversion, quit-protection while recording, floating mini mode, input-gain with soft limiter
- UI in English / 繁體中文 / 简体中文 / 日本語 / 한국어
- A build stamp in the footer, so you always know exactly which build you're running

## Requirements

- **macOS 14.4+** (system-audio Process Tap API) — **macOS 26.1+ recommended** for live transcription (26.0 has a known process-tap regression)
- **Swift 6 toolchain** — Xcode **Command Line Tools are enough** to build, run, and self-test. Full Xcode is only needed for `swift test`.

## Quick start

```bash
git clone <this-repo> && cd MyParrot
swift build                 # compile check
bash scripts/build-app.sh   # assemble, sign, install to ~/Applications
open ~/Applications/MyParrot.app
```

First launch asks for **Microphone**, **Speech Recognition**, and **System Audio Recording** permissions (it will *not* ask for Screen Recording).

## ⚠️ Gotchas (read these, they will save you an hour)

1. **Signing & permission persistence.** macOS ties permission grants (TCC) to the signing identity. `build-app.sh` auto-picks the best available: an Apple Development / Developer ID certificate (has a Team ID → **permissions survive rebuilds**) → a self-signed cert → ad-hoc (**permissions re-asked on every rebuild**). If you have any Apple certificate, the script will find and use it.
2. **Keep the `.app` out of iCloud-synced folders.** iCloud Drive re-applies Finder xattrs that repeatedly break code signatures. This is why the script installs to `~/Applications`.
3. **Don't use a Bluetooth mic.** The moment any app opens a Bluetooth microphone, the whole link drops from A2DP to narrowband HFP — the *other side's* audio degrades to phone quality too. Wear the headset for listening; speak into the built-in or a wired/USB mic. (MyParrot's auto-selection already avoids Bluetooth mics; picking one manually is allowed but warned.)

## Known limitations

| Area | Status |
| --- | --- |
| Long meetings (>30 min) | The two capture clocks drift slowly; sample-accurate sync is planned |
| Bluetooth headset as *output* while any app holds a BT mic | Phone-quality ceiling — protocol limitation (HFP), not fixable in software |
| Hot-swapping *to* a Bluetooth mic mid-recording | One audible pop at the switch (OS profile change) |
| Capture gaps shorter than 0.3 s | Not silence-padded (trade-off that eliminates padding clicks); the track may shift ≤0.3 s early in that window |
| Echo cancellation | Offline post-process only, off by default |

## Legal

Recording calls without consent is illegal in many jurisdictions. **You are responsible** for informing participants and obtaining consent where required.

## Architecture

```
Sources/MyParrotCore/        Library: capture, mux, transcription, export
  SystemAudioCapture.swift   Other side: global process tap (+ true-rate relabeling for BT/HFP)
  MicCapture.swift           You: AVAudioEngine + configuration-change self-heal
  StereoRecorder.swift       Two feeds → one stereo file (L=them, R=you), min-paced drain
  AudioUtils.swift           SampleQueue (ramped padding), 48 kHz mono converter, RMS
  RecordingController.swift  State machine, device watchdog, conversion, playback
  EchoCleanup / EchoCanceller / DelayEstimator   Offline AEC (bulk-delay + NLMS)
  Transcription/             SpeechAnalyzer (live + file) with SFSpeech fallback
  SelfTest.swift             12 self-test cases (shared by CLI runner & swift test)
Sources/MyParrot/            SwiftUI app (main window, mini mode, settings, mascot)
Sources/MyParrotSelfTest/    CLI test runner — works with Command Line Tools only
Tests/MyParrotTests/         Swift Testing wrappers (one @Test per self-test case)
scripts/build-app.sh         Assemble + sign + install + build stamp
```

See [docs/TESTING.md](docs/TESTING.md) for the test pyramid and how to verify changes.

## License

MIT © 2026 Eric Lu — see [LICENSE](LICENSE).
