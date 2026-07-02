import Foundation
import Speech
import AVFoundation

/// MVP transcription using on-device SFSpeechRecognizer (繁中 zh-TW).
/// Splits the stereo recording into two mono streams so speaker attribution is
/// free: left = 對方, right = 你.
///
/// v1.1 TODO: migrate to macOS 26 SpeechAnalyzer / SpeechTranscriber for long-form
/// streaming + better accuracy; expose WhisperKit / cloud via TranscriptionProvider.
final class AppleSpeechProvider: TranscriptionProvider {
    let displayName = "macOS 原生(本機)"

    func transcribeFile(_ url: URL, locale: Locale) async throws -> [TranscriptLine] {
        try await requestAuth()
        let (leftURL, rightURL) = try AudioChannelSplit.splitStereoToMono(url)
        defer {
            if leftURL != url { try? FileManager.default.removeItem(at: leftURL) }
            if rightURL != url { try? FileManager.default.removeItem(at: rightURL) }
        }
        let other = try await recognize(leftURL, isYou: false, locale: locale)
        let you = try await recognize(rightURL, isYou: true, locale: locale)
        return (other + you).sorted { $0.time < $1.time }
    }

    private func requestAuth() async throws {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw "語音辨識未授權" }
    }

    private func recognize(_ url: URL, isYou: Bool, locale: Locale) async throws -> [TranscriptLine] {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw "辨識引擎不可用" }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let base = Date()

        return try await withCheckedThrowingContinuation { cont in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                if done { return }
                if let error { done = true; cont.resume(throwing: error); return }
                guard let result, result.isFinal else { return }
                done = true
                let text = result.bestTranscription.formattedString
                guard !text.isEmpty else { cont.resume(returning: []); return }
                let segs = result.bestTranscription.segments
                let start = segs.first?.timestamp ?? 0
                let end = segs.last.map { $0.timestamp + $0.duration } ?? start
                cont.resume(returning: [TranscriptLine(isYou: isYou,
                                                        time: base.addingTimeInterval(start),
                                                        text: text,
                                                        isFinal: true,
                                                        start: start,
                                                        duration: max(0, end - start))])
            }
        }
    }

}
