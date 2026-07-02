import Foundation
import Speech
import AVFoundation
import os

/// Live, on-device transcription of both channels during recording.
/// 對方 (system audio) and 你 (microphone) get separate recognition streams so
/// the chat-bubble pane fills in with the right speaker, live.
///
/// v1.1 TODO: migrate to macOS 26 SpeechAnalyzer for long-form streaming without
/// the SFSpeech ~1-minute window (we auto-restart each stream here as a stopgap).
final class LiveTranscriber: LiveTranscribing, @unchecked Sendable {

    /// Called on the main queue whenever the line list changes.
    var onUpdate: (([TranscriptLine]) -> Void)?

    private var locale = Locale(identifier: "zh-TW")
    private var otherStream: Stream?
    private var youStream: Stream?
    private var lines: [TranscriptLine] = []
    private(set) var isActive = false

    func start(locale: Locale) {
        self.locale = locale
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, status == .authorized else { return }
                self.isActive = true
                self.lines = []
                self.otherStream = Stream(isYou: false, locale: self.locale) { [weak self] in self?.commit($0, isYou: false) }
                self.youStream = Stream(isYou: true, locale: self.locale) { [weak self] in self?.commit($0, isYou: true) }
            }
        }
    }

    func appendSystem(_ buffer: AVAudioPCMBuffer) { otherStream?.append(buffer) }
    func appendMic(_ buffer: AVAudioPCMBuffer) { youStream?.append(buffer) }

    func stop() {
        isActive = false
        otherStream?.finish(); otherStream = nil
        youStream?.finish(); youStream = nil
    }

    // Replace the live (non-final) line for a speaker, or append a final one.
    private func commit(_ line: TranscriptLine, isYou: Bool) {
        if let idx = lines.lastIndex(where: { $0.isYou == isYou && !$0.isFinal }) {
            if line.text.isEmpty { lines.remove(at: idx) } else { lines[idx] = line }
        } else if !line.text.isEmpty {
            lines.append(line)
        }
        lines.sort { $0.time < $1.time }
        onUpdate?(lines)
    }

    /// One speaker's recognition stream, with auto-restart on the SFSpeech window.
    ///
    /// `@unchecked Sendable` because `request` / `task` / `active` / `streamStart`
    /// are touched from several threads: the AVAudioEngine render (audio I/O)
    /// thread via `append()`, the SFSpeech callback queue via `restart()`, and
    /// @MainActor / stop via `finish()`. Today the render side is single-threaded
    /// (the old tap is fully quiesced before a mic hot-swap installs a new one),
    /// but we serialise every access with `lock` instead of relying on that
    /// lock-free invariant. os_unfair_lock keeps the real-time `append()` path
    /// cheap (uncontended lock/unlock is a few ns) and donates priority.
    private final class Stream: @unchecked Sendable {
        private let isYou: Bool
        private let locale: Locale
        private let onLine: (TranscriptLine) -> Void
        private let recognizer: SFSpeechRecognizer?
        private let lock = OSAllocatedUnfairLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var task: SFSpeechRecognitionTask?
        private var active = true
        private var streamStart = Date()

        init(isYou: Bool, locale: Locale, onLine: @escaping (TranscriptLine) -> Void) {
            self.isYou = isYou; self.locale = locale; self.onLine = onLine
            self.recognizer = SFSpeechRecognizer(locale: locale)
            begin()
        }

        private func begin() {
            let canStart = lock.withLockUnchecked { active }
            guard canStart, let recognizer, recognizer.isAvailable else { return }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.requiresOnDeviceRecognition = true
            req.shouldReportPartialResults = true
            lock.withLockUnchecked {
                streamStart = Date()
                request = req
            }
            // recognitionTask may fire the callback (→ restart → lock) on another
            // queue, so start it without holding the lock to avoid contention.
            let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let line = TranscriptLine(isYou: self.isYou, time: Date(),
                                              text: result.bestTranscription.formattedString,
                                              isFinal: result.isFinal)
                    DispatchQueue.main.async { self.onLine(line) }
                    if result.isFinal { self.restart() }
                } else if error != nil {
                    self.restart()
                }
            }
            lock.withLockUnchecked { task = t }
        }

        private func restart() {
            let (req, canRestart) = lock.withLockUnchecked { () -> (SFSpeechAudioBufferRecognitionRequest?, Bool) in
                let r = request; request = nil; task = nil
                return (r, active)
            }
            req?.endAudio()
            guard canRestart else { return }
            begin()
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            // SFSpeech window is ~1 min; proactively cycle.
            let needsCycle = lock.withLockUnchecked { Date().timeIntervalSince(streamStart) > 50 && request != nil }
            if needsCycle { restart() }
            let req = lock.withLockUnchecked { request }
            req?.append(buffer)
        }

        func finish() {
            let (req, t) = lock.withLockUnchecked { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
                active = false
                let r = request; request = nil
                let tk = task; task = nil
                return (r, tk)
            }
            req?.endAudio()
            t?.cancel()
        }
    }
}
