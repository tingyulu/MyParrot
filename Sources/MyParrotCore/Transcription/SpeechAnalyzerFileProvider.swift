import Foundation
import AVFoundation
import Speech

/// File (after-the-fact) transcription using the macOS 26 SpeechAnalyzer /
/// SpeechTranscriber engine — the SAME engine as the live transcript, so results
/// are consistent and long recordings stream instead of choking like the old
/// SFSpeech file path. Splits L=對方 / R=你 for free speaker attribution.
@available(macOS 26.0, *)
final class SpeechAnalyzerFileProvider: TranscriptionProvider, @unchecked Sendable {
    let displayName = "macOS 原生(SpeechAnalyzer·本機)"

    func transcribeFile(_ url: URL, locale: Locale) async throws -> [TranscriptLine] {
        let (leftURL, rightURL) = try AudioChannelSplit.splitStereoToMono(url)
        defer {
            if leftURL != url { try? FileManager.default.removeItem(at: leftURL) }
            if rightURL != url { try? FileManager.default.removeItem(at: rightURL) }
        }
        // One shared time base so 對方/你 interleave by real file position.
        let base = Date()
        let other = try await transcribe(leftURL, isYou: false, locale: locale, base: base)
        let you = try await transcribe(rightURL, isYou: true, locale: locale, base: base)
        return (other + you).sorted { $0.time < $1.time }
    }

    private func transcribe(_ url: URL, isYou: Bool, locale: Locale, base: Date) async throws -> [TranscriptLine] {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])
        // Make sure the on-device model for this locale is present.
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)
        // `finishAfterFile` lets the analyzer read the whole file then finalize on
        // its own — that ends `transcriber.results`, so a single consumer loop is
        // enough (no extra Task to deadlock or orphan on an error path).
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var lines: [TranscriptLine] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            guard !text.isEmpty else { continue }
            lines.append(TranscriptLine(isYou: isYou,
                                        time: base.addingTimeInterval(result.range.start.seconds),
                                        text: text,
                                        isFinal: result.isFinal,
                                        start: result.range.start.seconds,
                                        duration: result.range.duration.seconds))
        }
        _ = analyzer   // keep alive until the file is fully consumed
        return lines
    }
}
