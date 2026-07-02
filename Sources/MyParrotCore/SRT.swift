import Foundation

/// Renders transcript lines as a SubRip (.srt) subtitle file — numbered cues with
/// `HH:MM:SS,mmm --> HH:MM:SS,mmm` timecodes and a speaker prefix, so the timed
/// transcript opens in any player / editor (Premiere, DaVinci, VLC, YouTube…).
enum SRT {
    static func make(from lines: [TranscriptLine]) -> String {
        let cues = lines.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start }
        var out = ""
        for (i, line) in cues.enumerated() {
            let start = max(0, line.start)
            // End = start+duration; if the engine gave no duration, run up to the
            // next cue's start (min 0.5s) so the cue stays on screen, never zero-length.
            var end = line.duration > 0 ? start + line.duration : 0
            if end <= start {
                let next = i + 1 < cues.count ? cues[i + 1].start : start + 2
                end = max(next, start + 0.5)
            }
            let speaker = line.isYou ? "你" : "對方"
            out += "\(i + 1)\n\(timecode(start)) --> \(timecode(end))\n\(speaker): \(line.text)\n\n"
        }
        return out
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let whole = Int(total)
        let ms = Int((total - Double(whole)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", whole / 3600, (whole % 3600) / 60, whole % 60, ms)
    }
}
