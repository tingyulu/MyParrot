# Contributing

Small project, simple rules. All of them exist because breaking them has already cost real recordings.

## Before you open a PR

1. **`swift build` + `swift run MyParrotSelfTest` must pass** (12/12). This works with Command Line Tools alone. With full Xcode, `swift test` runs the same cases via Swift Testing.
2. **Pure-logic change?** Add a `SelfTest` case in `Sources/MyParrotCore/SelfTest.swift` + a matching one-line `@Test` in `Tests/MyParrotTests/SelfTestCases.swift`. Test logic lives in one place; both runners share it.
3. **Audio-path change?** (capture, device handling, transcription, anything touching real I/O) — a green build proves nothing here. **Actually exercise the changed path** with a real microphone / real audio before the PR, and say in the PR description how you verified it. History lesson: a "fully green" build once shipped a transcriber that crashed on first use, and a device-change handler that silently recorded 40 minutes of nothing.
4. **Keep diffs lean.** If a var, guard, or abstraction defends against something that cannot happen, delete it.

## Known trap when testing locally

macOS ties permission grants to the code-signing identity. If you build with ad-hoc signing, every rebuild re-asks for mic/system-audio permissions — that's expected, not a bug. Any Apple Development certificate in your keychain fixes it (`scripts/build-app.sh` picks it up automatically).

## Filing issues

Include: macOS version, how you built (script vs `swift run`), the **build stamp** shown in the app's lower-left corner, and — for audio problems — whether any Bluetooth device was connected. Attach Console output if the app logged anything.

## License

By contributing you agree your contributions are licensed under the MIT license.
