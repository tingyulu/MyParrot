import Foundation

/// A finished recording on disk.
public struct Recording: Identifiable, Hashable {
    public let id: UUID
    public var title: String          // e.g. "客戶會議-CMoney"
    public var url: URL
    public var date: Date
    public var duration: TimeInterval
    public var hasTranscript: Bool
    public var savedToDrive: Bool
    public var isConverting: Bool

    public init(id: UUID, title: String, url: URL, date: Date,
                duration: TimeInterval, hasTranscript: Bool, savedToDrive: Bool,
                isConverting: Bool = false) {
        self.id = id; self.title = title; self.url = url; self.date = date
        self.duration = duration; self.hasTranscript = hasTranscript; self.savedToDrive = savedToDrive
        self.isConverting = isConverting
    }

    /// Display filename per the PRD template: 日期+時間+會議名稱
    public static func fileName(date: Date, title: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = f.string(from: date)
        let safe = title.isEmpty ? "錄音" : title
        return "\(stamp) \(safe).caf"
    }
}

/// One line of transcript. `isYou` decides bubble side (right) vs 對方 (left).
public struct TranscriptLine: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var isYou: Bool
    public var time: Date
    public var text: String
    public var isFinal: Bool
    /// Offset from the recording start, in seconds (for SRT timecodes). 0 if unknown.
    public var start: TimeInterval
    /// Length of this cue in seconds (for SRT end time). 0 if unknown.
    public var duration: TimeInterval

    public init(isYou: Bool, time: Date, text: String, isFinal: Bool,
                start: TimeInterval = 0, duration: TimeInterval = 0) {
        self.isYou = isYou; self.time = time; self.text = text; self.isFinal = isFinal
        self.start = start; self.duration = duration
    }
}

public enum RecordingState: Equatable, Sendable {
    case idle        // 待錄音
    case recording   // 錄音中
    case paused      // 已暫停
    case finished    // 結束後
}
