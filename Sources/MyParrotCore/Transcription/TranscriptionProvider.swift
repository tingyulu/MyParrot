import Foundation

/// Pluggable transcription layer. MVP ships an on-device Apple provider; the
/// protocol leaves room for WhisperKit (better 中英混講) or a bring-your-own
/// cloud API, selectable in Settings — without touching the rest of the app.
protocol TranscriptionProvider: AnyObject, Sendable {
    var displayName: String { get }

    /// Transcribe a finished file. `channel`-aware providers may split L/對方 vs R/你.
    func transcribeFile(_ url: URL, locale: Locale) async throws -> [TranscriptLine]
}

/// Identifies which built-in engine to use.
public enum TranscriptionEngine: String, CaseIterable, Identifiable, Sendable {
    case appleNative    // macOS 26 SpeechAnalyzer (planned) / SFSpeechRecognizer (MVP)
    case whisperKit     // v1.1
    case cloud          // bring-your-own API, v1.1

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .appleNative: return "macOS 原生(繁中·本機)"
        case .whisperKit:  return "WhisperKit"
        case .cloud:       return "自帶 API"
        }
    }
}
