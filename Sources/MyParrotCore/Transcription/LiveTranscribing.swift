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
    func stop()
}
