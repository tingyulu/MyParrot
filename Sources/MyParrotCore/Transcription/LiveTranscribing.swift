import Foundation
import AVFoundation

/// Common interface for the live (during-recording) transcription engines, so the
/// controller can pick SpeechAnalyzer (macOS 26) or SFSpeech (fallback) transparently.
protocol LiveTranscribing: AnyObject, Sendable {
    /// Called on the main queue whenever the line list changes.
    var onUpdate: (([TranscriptLine]) -> Void)? { get set }
    func start(locale: Locale)
    func appendSystem(_ buffer: AVAudioPCMBuffer)   // 對方
    func appendMic(_ buffer: AVAudioPCMBuffer)       // 你
    /// TR-31(#2676):停止這一段。引擎在 stop 之後還會送出「句界才定稿」的行(Apple 的
    /// `finalizeAndFinishThroughEndOfInput`、Whisper 的尾塊、SFSpeech 的 `endAudio` 後最後一筆),
    /// 這些行**不上屏**、收進剛關掉的那一段;兩聲道都收完(或超時 `LiveStopDrain.defaultTimeout`)
    /// 在 main 回呼**恰好一次**,帶這一段完整的行列表(含停止前已上屏的)。🚫 不阻塞呼叫端。
    /// `completion` nil ＝ 不需要結果(重入 start、CLI),引擎仍會把那一段收乾淨。
    func stop(completion: (@MainActor ([TranscriptLine]) -> Void)?)
}

extension LiveTranscribing {
    /// 舊呼叫端的寫法:停止、不等晚到的行。
    func stop() { stop(completion: nil) }
}
