import Foundation
import AVFoundation
import os

/// 純邏輯 VAD 切塊器(TR-15·self-test 覆蓋):吃 16k mono 樣本流,依能量與
/// 靜音邊界決定何時切出一塊送轉寫。段落式準即時:靜音 ≥0.6s 或塊滿 6s 即切;
/// 無聲塊直接丟棄(防 buffer 無限長大、也不浪費推理)。
struct VadChunker {
    struct Chunk { let samples: [Float]; let startOffset: Int }   // offset=絕對樣本數

    /// 切塊參數(TR-28,#2485):live 段落式準即時(6 s)與會後重轉(25 s)共用同一個切塊器,
    /// 只差門檻。file profile 塊長取 whisper 原生 30 秒窗以內、尾靜音放寬到 0.8 s 少切斷句。
    struct Profile: Sendable {
        let silenceCut: Int                  // 尾靜音達此樣本數 → 切
        let maxChunk: Int                    // 塊滿此樣本數 → 強制切
        let minVoiced: Int                   // 有聲跨度不足 → 丟
        let idleDrop: Int                    // 全靜音達此樣本數 → 丟
        static let live = Profile(silenceCut: 9_600, maxChunk: 96_000, minVoiced: 8_000, idleDrop: 48_000)
        static let file = Profile(silenceCut: 12_800, maxChunk: 400_000, minVoiced: 8_000, idleDrop: 48_000)
    }

    let profile: Profile
    init(profile: Profile = .live) { self.profile = profile }

    private(set) var samples: [Float] = []
    private(set) var consumed = 0            // samples[0] 的絕對樣本偏移
    private var firstVoice = -1              // 絕對樣本索引(-1=本塊尚無聲)
    private var lastVoice = -1

    static let rate = 16_000
    static let voiceRMS: Float = 0.012       // 10ms 塊 RMS 門檻
    static let silenceCut = Profile.live.silenceCut   // 0.6s 尾靜音 → 切(live)
    static let maxChunk = Profile.live.maxChunk       // 6s 強制切(live)
    static let minVoiced = Profile.live.minVoiced     // 有聲跨度 ≥0.5s 才值得轉
    static let idleDrop = Profile.live.idleDrop       // 3s 全靜音 → 丟

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

        if samples.count >= profile.maxChunk {
            return voicedSpan >= profile.minVoiced ? [cut()] : { drop(); return [] }()
        }
        if firstVoice >= 0, trailingSilence >= profile.silenceCut {
            if voicedSpan >= profile.minVoiced { return [cut()] }
            drop(); return []                 // 只有雜訊尖峰,不值得轉
        }
        if firstVoice < 0, samples.count >= profile.idleDrop {
            drop(); return []
        }
        return []
    }

    mutating func flush() -> Chunk? {
        defer { drop() }
        guard firstVoice >= 0, (lastVoice - firstVoice) >= profile.minVoiced else { return nil }
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
        /// TR-29:這一段的 generation,start() 在同一個 lock 內與 chunker 一起重設;塊與代數永遠在同一臨界區取得(二審第二輪)。
        var gen = 0
        /// TR-31(二審):「還收不收新塊」與 inflight 同一把鎖——stop 在數 inflight 的同一臨界區把它關掉,
        /// 之後 append 連塊都不產生,expected 數完就不會再長(原本只靠 main 上的 `running`,render 執行緒讀它沒同步)。
        var accepting = false
        let lock = NSLock()
        init(isYou: Bool) { self.isYou = isYou }
        /// 辨識 task 回來時的收尾(同步包裝:NSLock 禁止在 async 函式內直接 lock)。二審第三輪:先驗代數——
        /// 這個塊若屬於上一段,**不碰這一段的 inflight／gate**,回 nil 讓呼叫端整個略過(commit 也會因舊代被擋);
        /// 通過代數才扣 inflight、過幻覺閘,回要上屏的字(空字串＝抑制)。
        func complete(generation gen: Int, text: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            guard gen == self.gen else { return nil }
            inflight -= 1
            return gate.check(text) ? text : ""
        }
    }
    private let you = Channel(isYou: true)
    private let other = Channel(isYou: false)

    /// TR-29(#2672):行列表與 generation 共用 `LiveLineBuffer`;stop() 的尾塊在 Task.detached 裡幾秒後才回來,
    /// 若那時下一段已開錄,帶舊代的 commit 不會塞進新段。TR-31(#2676):外層 `LiveLineStore` 把它收進已關的那一段,
    /// 由 `LiveStopDrain` 在所有在飛的塊都回來(或超時)後交回。
    private let store = OSAllocatedUnfairLock(initialState: LiveLineStore())
    /// TR-31:每次 stop 一個 drain,以代數為鍵;塊回來時與 `Channel.complete` 在同一臨界區查(見 `finishChunk`),
    /// 「停止時數在飛的塊」與「塊回來扣數」才對得上。
    private let drainLock = OSAllocatedUnfairLock()
    private var drains: [Int: LiveStopDrain] = [:]
    private var startDate = Date()
    private var running = false

    init(engine: WhisperCppEngine) {
        self.engine = engine
    }

    func start(locale: Locale) {
        langCode = WhisperLang.code(for: locale)
        prompt = WhisperLang.prompt(for: langCode)
        startDate = Date()
        if running { stop(completion: nil) }   // 重入保護:上一段照 stop 收尾(尾塊進它自己那段)
        let gen = store.withLock { $0.start() }   // TR-29:清上一段、換代;TR-31:標開著
        for ch in [you, other] {
            ch.lock.lock()
            ch.chunker = VadChunker(); ch.inflight = 0; ch.dropped = 0; ch.gate = HallucinationGate(); ch.gen = gen; ch.accepting = true
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
        guard ch.accepting else { ch.lock.unlock(); return }   // stop 已在同一把鎖內關掉:不再切塊、不再加 inflight
        let pcm16k = ch.conv.convert(buffer)
        let chunks = ch.chunker.feed(pcm16k)
        var toRun: [VadChunker.Chunk] = []
        let gen = ch.gen   // 與 chunks 同一臨界區
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
        for c in toRun { transcribe(c, ch: ch, generation: gen) }
    }

    private func transcribe(_ chunk: VadChunker.Chunk, ch: Channel, generation gen: Int) {
        let t0 = Double(chunk.startOffset) / Double(VadChunker.rate)
        let dur = Double(chunk.samples.count) / Double(VadChunker.rate)
        let lineTime = startDate.addingTimeInterval(t0)
        // 上屏 volatile 佔位(「⋯」),結果回來替換。
        commit(TranscriptLine(isYou: ch.isYou, time: lineTime, text: "⋯",
                              isFinal: false, start: t0, duration: dur), generation: gen)
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
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let (show, drain) = self.finishChunk(ch, generation: gen, text: trimmed)
            // show nil ＝ 聲道已換代(下一段開錄了):不碰新段的 inflight／幻覺閘,但這個塊仍屬上一段,
            // 照舊代 commit——store 會把它收進那一段的 closing(或已收尾 ⇒ stale 留 log)。
            if show == nil {
                os_log("MyParrot whisper live: 上一段的塊才回來,交給那一段收尾(gen %d,%{public}@)", gen, ch.isYou ? "你" : "對方")
            } else if show == "", !trimmed.isEmpty {
                os_log("MyParrot whisper live: 疑似幻覺複讀,已抑制上屏(%{public}@)", ch.isYou ? "你" : "對方")
            }
            self.commit(TranscriptLine(isYou: ch.isYou, time: lineTime,
                                       text: show ?? trimmed, isFinal: true, start: t0, duration: dur), generation: gen)
            drain?.arrive()   // commit 之後才報到:drain 在 main 取走時這一行已經在 store 裡
        }
    }

    /// TR-31:塊回來的收尾——`Channel.complete`(扣 inflight、過閘)與「這一代有沒有 drain 在等」在同一臨界區,
    /// 與 `stop(completion:)` 數在飛的塊互斥:一個塊要嘛在停止前就扣掉(不計入 expected、也拿不到 drain),
    /// 要嘛停止後才回來(計入 expected、拿到 drain 報到一次),不會多報或漏報。
    private func finishChunk(_ ch: Channel, generation gen: Int, text: String) -> (show: String?, drain: LiveStopDrain?) {
        drainLock.withLockUnchecked {
            (ch.complete(generation: gen, text: text), drains[gen])
        }
    }

    /// 合併策略在 `LiveLineBuffer`(取代該講者最後一條 volatile,空字串移除,final 新增,依 time 排序);排好後回主緒。
    private func commit(_ line: TranscriptLine, generation gen: Int) {
        switch store.withLock({ $0.commit(line, generation: gen) }) {
        case .active:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // 二審(第二輪):各 detached task 自己 enqueue,先後沒保證;上屏時重讀最新狀態並再驗代數,
                // 舊快照不會晚到回畫、新段 reset 後也不會被還在排隊的舊段快照蓋掉;TR-31:段已關也不上屏。
                let (open, g, lines) = self.store.withLock { ($0.isOpen, $0.generation, $0.lines) }
                guard open, g == gen else { return }
                self.onUpdate?(lines)
            }
        case .closing:
            break   // TR-31:上一段 stop() 後才回來的塊——收進那一段、不上屏,LiveStopDrain 收齊後交回
        case .stale:
            os_log("MyParrot whisper live: 忽略已收尾那段晚到的塊(gen %d,%{public}@)", gen, line.isYou ? "你" : "對方")
        }
    }

    /// TR-31:關掉這一段、送出兩聲道的尾塊;所有在飛的塊(含尾塊)都回來或超時 ⇒ 在 main 交出完整行列表一次。
    func stop(completion: (@MainActor ([TranscriptLine]) -> Void)?) {
        guard running, let gen = store.withLock({ $0.close() }) else {
            if let completion { Task { @MainActor in completion([]) } }
            return
        }
        running = false
        var tails: [(VadChunker.Chunk, Channel)] = []
        let store = self.store
        let drain = drainLock.withLockUnchecked { () -> LiveStopDrain in
            var pending = 0
            for ch in [you, other] {
                ch.lock.lock()
                ch.accepting = false            // 與下面的計數同一臨界區:之後的 append 不再產生塊
                let tail = ch.chunker.flush()   // 尾塊仍屬這一段(ch.gen == gen);回來時若下一段已開錄,commit 進 closing
                if tail != nil { ch.inflight += 1 }
                pending += ch.inflight
                ch.lock.unlock()
                if let tail { tails.append((tail, ch)) }
            }
            let d = LiveStopDrain(generation: gen, label: "whisper", expected: pending,
                                  take: { store.withLock { $0.takeClosing(gen) } },
                                  onDone: { [weak self] lines in
                                      self?.drainLock.withLockUnchecked { _ = self?.drains.removeValue(forKey: gen) }
                                      completion?(lines)
                                  })
            drains[gen] = d
            return d
        }
        for (tail, ch) in tails { transcribe(tail, ch: ch, generation: gen) }
        drain.activate()
    }
}
