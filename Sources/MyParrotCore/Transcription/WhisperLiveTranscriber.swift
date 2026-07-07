import Foundation
import AVFoundation
import os

/// 純邏輯 VAD 切塊器(TR-15·self-test 覆蓋):吃 16k mono 樣本流,依能量與
/// 靜音邊界決定何時切出一塊送轉寫。段落式準即時:靜音 ≥0.6s 或塊滿 6s 即切;
/// 無聲塊直接丟棄(防 buffer 無限長大、也不浪費推理)。
struct VadChunker {
    struct Chunk { let samples: [Float]; let startOffset: Int }   // offset=絕對樣本數

    private(set) var samples: [Float] = []
    private(set) var consumed = 0            // samples[0] 的絕對樣本偏移
    private var firstVoice = -1              // 絕對樣本索引(-1=本塊尚無聲)
    private var lastVoice = -1

    static let rate = 16_000
    static let voiceRMS: Float = 0.012       // 10ms 塊 RMS 門檻
    static let silenceCut = 9_600            // 0.6s 尾靜音 → 切
    static let maxChunk = 96_000             // 6s 強制切
    static let minVoiced = 8_000             // 有聲跨度 ≥0.5s 才值得轉
    static let idleDrop = 48_000             // 3s 全靜音 → 丟

    mutating func feed(_ new: [Float]) -> [Chunk] {
        guard !new.isEmpty else { return [] }
        let baseAbs = consumed + samples.count
        samples.append(contentsOf: new)
        // 逐 10ms 塊評估新進料的能量
        var i = 0
        while i + 160 <= new.count {
            var sum: Float = 0
            for j in i..<(i + 160) { sum += new[j] * new[j] }
            if sqrt(sum / 160) > Self.voiceRMS {
                if firstVoice < 0 { firstVoice = baseAbs + i }
                lastVoice = baseAbs + i + 160
            }
            i += 160
        }
        let end = consumed + samples.count
        let trailingSilence = end - max(lastVoice, consumed)
        let voicedSpan = (firstVoice >= 0) ? (lastVoice - firstVoice) : 0

        if samples.count >= Self.maxChunk {
            return voicedSpan >= Self.minVoiced ? [cut()] : { drop(); return [] }()
        }
        if firstVoice >= 0, trailingSilence >= Self.silenceCut {
            if voicedSpan >= Self.minVoiced { return [cut()] }
            drop(); return []                 // 只有雜訊尖峰,不值得轉
        }
        if firstVoice < 0, samples.count >= Self.idleDrop {
            drop(); return []
        }
        return []
    }

    mutating func flush() -> Chunk? {
        defer { drop() }
        guard firstVoice >= 0, (lastVoice - firstVoice) >= Self.minVoiced else { return nil }
        return Chunk(samples: samples, startOffset: consumed)
    }

    private mutating func cut() -> Chunk {
        let c = Chunk(samples: samples, startOffset: consumed)
        drop()
        return c
    }

    private mutating func drop() {
        consumed += samples.count
        samples.removeAll(keepingCapacity: true)
        firstVoice = -1; lastVoice = -1
    }
}

/// 幻覺防呆②(TR-15·self-test 覆蓋):偵測「連續幾塊輸出一字不差」。
/// 音樂等非語音音訊有時能騙過 no_speech_prob、被模型鎖死複讀同一句
/// (temperature=0 貪婪解碼+每塊內容相似→決定性重複輸出)。同句連續
/// ≥3 塊才視為幻覺並壓下(前兩次仍正常顯示,不誤殺真實的短句重複)。
struct HallucinationGate {
    private var lastText = ""
    private var streak = 0

    /// 回傳 true = 正常上屏,false = 疑似失控複讀、應壓下(不上屏)。
    mutating func check(_ text: String) -> Bool {
        guard !text.isEmpty else { streak = 0; lastText = ""; return true }
        if text == lastText {
            streak += 1
        } else {
            streak = 1
            lastText = text
        }
        return streak < 3
    }
}

/// whisper.cpp 準即時逐字稿(段落式,3-7s 上屏)。每聲道:16k 重採樣 →
/// VadChunker → WhisperCppEngine(actor 序列化)→ TranscriptLine。
/// 中文輸出過 ZhTW(s2twp)。背壓:每聲道最多 2 塊在飛,超過丟最舊防雪崩。
final class WhisperLiveTranscriber: LiveTranscribing, @unchecked Sendable {

    var onUpdate: (([TranscriptLine]) -> Void)?

    private let engine: WhisperCppEngine
    private var langCode: String?
    private var prompt: String?

    /// @unchecked Sendable:可變狀態(chunker/inflight/dropped/gate)全在 `lock` 內。
    private final class Channel: @unchecked Sendable {
        let isYou: Bool
        let conv = MonoDownconverter(sampleRate: 16_000)
        var chunker = VadChunker()
        var inflight = 0
        var dropped = 0
        var gate = HallucinationGate()
        let lock = NSLock()
        init(isYou: Bool) { self.isYou = isYou }
        /// 同步包裝:供 async context 呼叫(NSLock 禁止在 async 函式內直接 lock)。
        func finishOne() { lock.lock(); inflight -= 1; lock.unlock() }
        func checkRepeat(_ text: String) -> Bool { lock.lock(); defer { lock.unlock() }; return gate.check(text) }
    }
    private let you = Channel(isYou: true)
    private let other = Channel(isYou: false)

    private var lines: [TranscriptLine] = []
    private let linesLock = NSLock()
    private var startDate = Date()
    private var running = false

    init(engine: WhisperCppEngine) {
        self.engine = engine
    }

    func start(locale: Locale) {
        langCode = WhisperLang.code(for: locale)
        prompt = WhisperLang.prompt(for: langCode)
        startDate = Date()
        linesLock.lock(); lines = []; linesLock.unlock()
        for ch in [you, other] {
            ch.lock.lock()
            ch.chunker = VadChunker(); ch.inflight = 0; ch.dropped = 0; ch.gate = HallucinationGate()
            ch.lock.unlock()
        }
        running = true
        onUpdate?([])
    }

    func appendMic(_ buffer: AVAudioPCMBuffer)    { append(buffer, to: you) }
    func appendSystem(_ buffer: AVAudioPCMBuffer) { append(buffer, to: other) }

    private func append(_ buffer: AVAudioPCMBuffer, to ch: Channel) {
        guard running else { return }
        ch.lock.lock()
        let pcm16k = ch.conv.convert(buffer)
        let chunks = ch.chunker.feed(pcm16k)
        var toRun: [VadChunker.Chunk] = []
        for c in chunks {
            if ch.inflight >= 2 {
                ch.dropped += 1
                os_log("MyParrot whisper live: 背壓丟塊(%{public}@ 累計 %d)",
                       ch.isYou ? "你" : "對方", ch.dropped)
            } else {
                ch.inflight += 1
                toRun.append(c)
            }
        }
        ch.lock.unlock()
        for c in toRun { transcribe(c, ch: ch) }
    }

    private func transcribe(_ chunk: VadChunker.Chunk, ch: Channel) {
        let t0 = Double(chunk.startOffset) / Double(VadChunker.rate)
        let dur = Double(chunk.samples.count) / Double(VadChunker.rate)
        let lineTime = startDate.addingTimeInterval(t0)
        // 上屏 volatile 佔位(「⋯」),結果回來替換。
        commit(TranscriptLine(isYou: ch.isYou, time: lineTime, text: "⋯",
                              isFinal: false, start: t0, duration: dur), isYou: ch.isYou)
        let lang = langCode, prompt = prompt, engine = engine
        Task.detached(priority: .userInitiated) { [weak self, weak ch] in
            var text = ""
            do {
                let segs = try await engine.transcribe(samples16k: chunk.samples,
                                                       languageCode: lang, prompt: prompt)
                text = segs.map(\.text).joined(separator: " ")
                if lang == "zh" { text = ZhTW.convert(text) }
            } catch {
                os_log("MyParrot whisper live: 轉寫失敗 %{public}@", "\(error)")
            }
            guard let self, let ch else { return }
            ch.finishOne()
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let show: String
            if ch.checkRepeat(trimmed) {
                show = trimmed
            } else {
                show = ""
                os_log("MyParrot whisper live: 疑似幻覺複讀,已抑制上屏(%{public}@)", ch.isYou ? "你" : "對方")
            }
            self.commit(TranscriptLine(isYou: ch.isYou, time: lineTime,
                                       text: show, isFinal: true, start: t0, duration: dur), isYou: ch.isYou)
        }
    }

    /// 同 LiveTranscriber 的合併策略:取代該講者最後一條 volatile,空字串移除,
    /// final 新增;依 time 排序後回主緒。
    private func commit(_ line: TranscriptLine, isYou: Bool) {
        linesLock.lock()
        if let idx = lines.lastIndex(where: { $0.isYou == isYou && !$0.isFinal }) {
            if line.text.isEmpty { lines.remove(at: idx) } else { lines[idx] = line }
        } else if !line.text.isEmpty {
            lines.append(line)
        }
        lines.sort { $0.time < $1.time }
        let snapshot = lines
        linesLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snapshot) }
    }

    func stop() {
        guard running else { return }
        running = false
        for ch in [you, other] {
            ch.lock.lock()
            let tail = ch.chunker.flush()
            if tail != nil { ch.inflight += 1 }
            ch.lock.unlock()
            if let tail { transcribe(tail, ch: ch) }
        }
    }
}
