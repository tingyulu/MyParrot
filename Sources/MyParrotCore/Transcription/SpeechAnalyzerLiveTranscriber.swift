import Foundation
import AVFoundation
import Speech
import os

/// Live transcription using the macOS 26 SpeechAnalyzer / SpeechTranscriber engine.
/// Proper long-form streaming (no SFSpeech ~1-minute window), on-device, 繁中.
/// 對方 (system) and 你 (mic) each get their own analyzer pipeline so speaker
/// attribution stays correct.
@available(macOS 26.0, *)
final class SpeechAnalyzerLiveTranscriber: LiveTranscribing, @unchecked Sendable {

    var onUpdate: (([TranscriptLine]) -> Void)?

    private var locale = Locale(identifier: "zh-TW")
    private var lines: [TranscriptLine] = []
    private var other: Channel?
    private var you: Channel?

    func start(locale: Locale) {
        self.locale = locale
        let o = Channel(isYou: false, locale: locale) { [weak self] in self?.commit($0, isYou: false) }
        let y = Channel(isYou: true, locale: locale) { [weak self] in self?.commit($0, isYou: true) }
        other = o; you = y
        Task { await o.begin() }
        Task { await y.begin() }
    }

    func appendSystem(_ buffer: AVAudioPCMBuffer) { other?.append(buffer) }
    func appendMic(_ buffer: AVAudioPCMBuffer) { you?.append(buffer) }

    func stop() {
        other?.finish(); you?.finish()
        other = nil; you = nil
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

    /// One speaker's SpeechAnalyzer pipeline.
    ///
    /// `@unchecked Sendable` because the mutable state below is reached from more
    /// than one thread: `begin()`/`finish()` run on a Task / @MainActor while
    /// `append()` is driven by the AVAudioEngine render (audio I/O) thread. Today
    /// only one render thread ever feeds a given Channel (RecordingController fully
    /// quiesces the old tap before installing the new one during a mic hot-swap),
    /// but rather than rely on that lock-free invariant we serialise every access
    /// to `continuation` / `analyzer` / `analyzerFormat` / `converter` /
    /// `converterSource` with `lock`. os_unfair_lock is the recommended primitive
    /// for the real-time path: uncontended lock/unlock is a few ns and it donates
    /// priority, so it stays correct if a second feed source is ever added.
    private final class Channel: @unchecked Sendable {
        private let isYou: Bool
        private let locale: Locale
        private let onLine: (TranscriptLine) -> Void

        private let lock = OSAllocatedUnfairLock()
        private var continuation: AsyncStream<AnalyzerInput>.Continuation?
        private var analyzer: SpeechAnalyzer?
        private var analyzerFormat: AVAudioFormat?
        private var converter: AVAudioConverter?
        private var converterSource: AVAudioFormat?
        private let startedAt = Date()

        init(isYou: Bool, locale: Locale, onLine: @escaping (TranscriptLine) -> Void) {
            self.isYou = isYou; self.locale = locale; self.onLine = onLine
        }

        func begin() async {
            do {
                let transcriber = SpeechTranscriber(locale: locale,
                                                    transcriptionOptions: [],
                                                    reportingOptions: [.volatileResults],
                                                    attributeOptions: [])
                // Make sure the on-device 繁中 model is present.
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await req.downloadAndInstall()
                }
                let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

                let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
                let a = SpeechAnalyzer(modules: [transcriber])
                // Publish the fields the audio thread reads in one critical section.
                lock.withLockUnchecked {
                    analyzerFormat = fmt
                    continuation = cont
                    analyzer = a
                }
                try await a.start(inputSequence: stream)

                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let line = TranscriptLine(isYou: isYou, time: startedAt.addingTimeInterval(result.range.start.seconds),
                                              text: text, isFinal: result.isFinal)
                    DispatchQueue.main.async { self.onLine(line) }
                }
            } catch {
                // Silent: live transcript is best-effort; recording itself is unaffected.
            }
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            // Convert under the lock (converter state is shared); yield outside it.
            let (cont, out) = lock.withLockUnchecked { () -> (AsyncStream<AnalyzerInput>.Continuation?, AVAudioPCMBuffer?) in
                let c = continuation
                return (c, c == nil ? nil : convert(buffer))
            }
            guard let cont, let out else { return }
            cont.yield(AnalyzerInput(buffer: out))
        }

        func finish() {
            let (cont, a) = lock.withLockUnchecked { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) in
                let c = continuation; continuation = nil
                let an = analyzer; analyzer = nil
                return (c, an)
            }
            cont?.finish()
            Task { try? await a?.finalizeAndFinishThroughEndOfInput() }
        }

        /// Caller must hold `lock` (it reads `analyzerFormat` and mutates `converter`/`converterSource`).
        private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            guard let fmt = analyzerFormat else { return nil }
            if input.format == fmt { return input }
            if converter == nil || converterSource != input.format {
                converter = AVAudioConverter(from: input.format, to: fmt)
                converterSource = input.format
            }
            guard let converter else { return nil }
            let ratio = fmt.sampleRate / input.format.sampleRate
            let cap = AVAudioFrameCount(Double(input.frameLength) * ratio + 16)
            guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return input
            }
            return err == nil ? out : nil
        }
    }
}
