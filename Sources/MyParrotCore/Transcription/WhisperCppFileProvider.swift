import Foundation
import AVFoundation

/// whisper.cpp 檔案轉錄:分軌(左=對方/右=你)→ 16k mono → 整檔轉寫 →
/// 帶時間戳合併。把「轉逐字稿」按鈕與 Phase C 自動重轉升級到 large-v3 級品質
///(= transcribe.sh 的 in-app 化,可望取代該手動流程)。
final class WhisperCppFileProvider: TranscriptionProvider, @unchecked Sendable {

    let displayName = "Whisper(本地)"
    private let engine: WhisperCppEngine

    init(engine: WhisperCppEngine) {
        self.engine = engine
    }

    func transcribeFile(_ url: URL, locale: Locale) async throws -> [TranscriptLine] {
        let (leftURL, rightURL) = try AudioChannelSplit.splitStereoToMono(url)
        defer {
            if leftURL != url { try? FileManager.default.removeItem(at: leftURL) }
            if rightURL != url { try? FileManager.default.removeItem(at: rightURL) }
        }
        let lang = WhisperLang.code(for: locale)
        let prompt = WhisperLang.prompt(for: lang)
        let base = Date()

        let other = try await transcribeMono(leftURL, isYou: false, lang: lang, prompt: prompt, base: base)
        let you = try await transcribeMono(rightURL, isYou: true, lang: lang, prompt: prompt, base: base)
        return (other + you).sorted { $0.time < $1.time }
    }

    private func transcribeMono(_ url: URL, isYou: Bool, lang: String?,
                                prompt: String?, base: Date) async throws -> [TranscriptLine] {
        let samples = try Self.loadMono16k(url)
        guard samples.count > 16_000 else { return [] }   // <1s 略過
        let segs = try await engine.transcribe(samples16k: samples, languageCode: lang, prompt: prompt)
        return segs.map { s in
            var text = s.text
            if lang == "zh" { text = ZhTW.convert(text) }
            return TranscriptLine(isYou: isYou, time: base.addingTimeInterval(s.start),
                                  text: text, isFinal: true, start: s.start, duration: s.duration)
        }
    }

    /// 讀任意音檔 → 16kHz mono Float(分塊讀,不整檔進記憶體兩份)。
    static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let conv = MonoDownconverter(sampleRate: 16_000)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) / file.processingFormat.sampleRate * 16_000) + 16)
        let chunkFrames: AVAudioFrameCount = 65_536
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: chunkFrames) else { break }
            try file.read(into: buf, frameCount: chunkFrames)
            if buf.frameLength == 0 { break }
            out.append(contentsOf: conv.convert(buf))
        }
        return out
    }
}
