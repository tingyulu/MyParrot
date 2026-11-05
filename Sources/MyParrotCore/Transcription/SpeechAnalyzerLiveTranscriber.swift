import Foundation
import AVFoundation
import Speech
import os

/// Live transcription using the macOS 26 SpeechAnalyzer / SpeechTranscriber engine.
/// Proper long-form streaming (no SFSpeech ~1-minute window), on-device, 繁中.
/// 對方 (system) and 你 (mic) each get their own analyzer pipeline so speaker
/// attribution stays correct.
@available(macOS 26.0, *)
final class SpeechAnalyzerLiveTranscriber: LiveTranscribing, @unchecked Sendable {

    var onUpdate: (([TranscriptLine]) -> Void)?

    private var locale = Locale(identifier: "zh-TW")
    /// TR-29(#2672):行列表與 generation 住在鎖裡,不靠「呼叫端都在 main」的慣例(二審指出 start/stop 沒有 actor 保證)。
    /// TR-31(#2676):外層換成 `LiveLineStore`——停止後晚到的定稿收進已關的那一段,由 `LiveStopDrain` 交回。
    private let store = OSAllocatedUnfairLock(initialState: LiveLineStore())
    private var other: Channel?
    private var you: Channel?

    func start(locale: Locale) {
        self.locale = locale
        // 重入保護:沒 stop 就再 start,先把上一段照 stop 收掉(舊 analyzer 收尾、晚到的行進它自己那段,不丟給這段)。
        if other != nil || you != nil { stop(completion: nil) }
        // TR-29:清掉上一段的行、換代;TR-31:同時標「開著」,舊代的 commit 依 store 分流。
        let gen = store.withLock { $0.start() }
        onUpdate?([])
        // TR-30:兩聲道共用同一個 0 點(開錄當下);lead 用單調時鐘算,牆鐘校時不會把字幕推歪(二審第二輪)
        let session = Date(), sessionUptime = ProcessInfo.processInfo.systemUptime
        let o = Channel(isYou: false, locale: locale, sessionStart: session, sessionUptime: sessionUptime) { [weak self] in self?.commit($0, generation: gen) }
        let y = Channel(isYou: true, locale: locale, sessionStart: session, sessionUptime: sessionUptime) { [weak self] in self?.commit($0, generation: gen) }
        other = o; you = y
        o.start(); y.start()
    }

    func appendSystem(_ buffer: AVAudioPCMBuffer) { other?.append(buffer) }
    func appendMic(_ buffer: AVAudioPCMBuffer) { you?.append(buffer) }

    /// TR-31:關掉這一段;兩個 Channel 的 results 迴圈自然結束(各 `arrive` 一次)或超時 ⇒ 在 main 交出完整行列表一次。
    func stop(completion: (@MainActor ([TranscriptLine]) -> Void)?) {
        let channels = [other, you].compactMap { $0 }
        other = nil; you = nil
        guard let gen = store.withLock({ $0.close() }) else {
            // 沒開著(沒 start 過或已 stop):沒東西可收,照契約仍回呼一次。
            if let completion { Task { @MainActor in completion([]) } }
            return
        }
        let store = self.store
        let drain = LiveStopDrain(generation: gen, label: "SpeechAnalyzer", expected: channels.count,
                                  take: { store.withLock { $0.takeClosing(gen) } },
                                  onTimeout: { channels.forEach { $0.cancelPending() } },   // 二審:超時要把掛著的 pipeline 收掉,不能永久活著
                                  onDone: completion)
        for ch in channels { ch.finish { drain.arrive() } }
        drain.activate()
    }

    // Replace the live (non-final) line for a speaker, or append a final one (rules live in LiveLineBuffer).
    private func commit(_ line: TranscriptLine, generation gen: Int) {
        switch store.withLock({ $0.commit(line, generation: gen) }) {
        case .active(let snapshot):
            onUpdate?(snapshot)
        case .closing:
            // TR-31:上一段 stop() 後才定稿的行——收進那一段、不上屏,LiveStopDrain 收齊後交回控制器補寫檔案。
            break
        case .stale:
            // 收尾已結束(或超時)才到:進不了任何一段;留 log 讓「尾句不見」查得到。
            os_log("MyParrot live: 忽略已收尾那段晚到的行(gen %d,%{public}@)", gen, line.isYou ? "你" : "對方")
        }
    }

    /// One speaker's SpeechAnalyzer pipeline.
    ///
    /// `@unchecked Sendable` because the mutable state below is reached from more
    /// than one thread: `begin()`/`finish()` run on a Task / @MainActor while
    /// `append()` is driven by the AVAudioEngine render (audio I/O) thread. Today
    /// only one render thread ever feeds a given Channel (RecordingController fully
    /// quiesces the old tap before installing the new one during a mic hot-swap),
    /// but rather than rely on that lock-free invariant we serialise every access
    /// to `continuation` / `analyzer` / `analyzerFormat` / `converter` /
    /// `converterSource` with `lock`. os_unfair_lock is the recommended primitive
    /// for the real-time path: uncontended lock/unlock is a few ns and it donates
    /// priority, so it stays correct if a second feed source is ever added.
    private final class Channel: @unchecked Sendable {
        private let isYou: Bool
        private let locale: Locale
        private let onLine: (TranscriptLine) -> Void

        private let lock = OSAllocatedUnfairLock()
        private var continuation: AsyncStream<AnalyzerInput>.Continuation?
        private var analyzer: SpeechAnalyzer?
        private var analyzerFormat: AVAudioFormat?
        private var converter: AVAudioConverter?
        private var converterSource: AVAudioFormat?
        /// TR-30:開錄當下,兩聲道共用(由 transcriber 傳入),是 .srt 時間碼的 0 點(牆鐘版給 `time`、單調版算 lead)。
        private let sessionStart: Date
        private let sessionUptime: TimeInterval
        /// TR-30:第一個**成功轉換並餵進** analyzer 的 buffer 時刻(單調時鐘)＝analyzer 時間軸的 0 點;begin() 好之前的 buffer 會被丟。
        private var firstFedUptime: TimeInterval?
        /// 重入／stop 保護:finish() 之後 begin() 不得再發表 pipeline(二審第二輪:finish 早於 continuation 建立時原本是 no-op)。
        private var finished = false
        /// TR-31:analyzer 已發表過(之後 finish 不取消 beginTask——取消會把 results 迴圈砍掉,停止後的定稿就到不了)。
        private var published = false
        /// TR-31:`begin()` 已整個跑完(results 迴圈結束或啟動失敗)。
        private var ended = false
        /// TR-31:finish(onDone:) 存進來,`begin()` 結束時呼叫一次。
        private var onDone: (() -> Void)?
        private var beginTask: Task<Void, Never>?

        init(isYou: Bool, locale: Locale, sessionStart: Date, sessionUptime: TimeInterval,
             onLine: @escaping (TranscriptLine) -> Void) {
            self.isYou = isYou; self.locale = locale; self.sessionStart = sessionStart
            self.sessionUptime = sessionUptime; self.onLine = onLine
        }

        func start() {
            beginTask = Task { await begin() }
        }

        private func begin() async {
            // TR-31:不論哪條路出去(啟動失敗、finish 前被取消、results 迴圈自然結束)都算這一聲道收完。
            defer { markDone() }
            do {
                let transcriber = SpeechTranscriber(locale: locale,
                                                    transcriptionOptions: [],
                                                    reportingOptions: [.volatileResults],
                                                    attributeOptions: [])
                // Make sure the on-device 繁中 model is present.
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await req.downloadAndInstall()
                }
                if Task.isCancelled { return }
                let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                if Task.isCancelled { return }

                let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
                let a = SpeechAnalyzer(modules: [transcriber])
                // Publish the fields the audio thread reads in one critical section;已 finish 就不發表。
                let accepted = lock.withLockUnchecked { () -> Bool in
                    if finished { return false }
                    analyzerFormat = fmt
                    continuation = cont
                    analyzer = a
                    published = true
                    return true
                }
                guard accepted else { cont.finish(); return }
                try await a.start(inputSequence: stream)
                // TR-31:發表之後不再查取消——finish() 只 finish 輸入串流並 finalize;停止後句界才定稿的行
                // 從這個迴圈走到尾,迴圈隨 analyzer 結束自然收掉(超時由 LiveStopDrain 兜底)。
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    // TR-30:analyzer 的 range 從第一個餵進去的 buffer 起算,所以錄音位移＝range.start ＋
                    // (第一個餵進去的 buffer 相對開錄的延遲);兩聲道共用 sessionStart,合併後在同一時間軸。
                    // 暫停期間 StereoRecorder(isPaused guard)與餵音都停,所以與檔案一致。
                    // 先淨化(NaN/負 → 0)再同時產 time 與 start,兩欄不會矛盾;無效 duration 退 0 交給 SRT.make 補齊。
                    let raw = result.range.start.seconds
                    let lead = (lock.withLockUnchecked { firstFedUptime } ?? sessionUptime) - sessionUptime
                    let offset = (raw.isFinite ? max(0, raw) : 0) + max(0, lead)
                    let du = result.range.duration.seconds
                    let line = TranscriptLine(isYou: isYou, time: sessionStart.addingTimeInterval(offset),
                                              text: text, isFinal: result.isFinal,
                                              start: offset, duration: du.isFinite && du > 0 ? du : 0)
                    DispatchQueue.main.async { self.onLine(line) }
                }
            } catch {
                // Best-effort:錄音本身不受影響,但不能靜默(二審第三輪)——留一行 error log 讓「開了卻沒稿」查得到。
                os_log(.error, "MyParrot live: SpeechAnalyzer pipeline 啟動／讀取失敗(%{public}@,%{public}@)", isYou ? "你" : "對方", "\(error)")
            }
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            // Convert under the lock (converter state is shared); yield outside it.
            let (cont, out) = lock.withLockUnchecked { () -> (AsyncStream<AnalyzerInput>.Continuation?, AVAudioPCMBuffer?) in
                let c = continuation
                return (c, c == nil ? nil : convert(buffer))
            }
            guard let cont, let out else { return }
            // TR-30:只有 yield 真的進佇列(.enqueued)才算「第一個餵進 analyzer 的 buffer」;finish 後的 .terminated／.dropped 不算(二審第三輪)。
            if case .enqueued = cont.yield(AnalyzerInput(buffer: out)) {
                lock.withLockUnchecked { if firstFedUptime == nil { firstFedUptime = ProcessInfo.processInfo.systemUptime } }
            }
        }

        /// 停止餵音並要 analyzer 收尾。`onDone` 在這一聲道整個結束時呼叫一次(已結束就立刻呼叫);
        /// 行會先經 main 排進 store,再輪到 onDone ⇒ drain 之後在 main 取走時一定包含它們。
        func finish(onDone: @escaping () -> Void) {
            let (cont, a, cancelBegin, alreadyEnded) = lock.withLockUnchecked {
                () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?, Bool, Bool) in
                finished = true
                let c = continuation; continuation = nil
                let an = analyzer; analyzer = nil
                if !ended { self.onDone = onDone }
                return (c, an, !published, ended)
            }
            // 還沒發表 analyzer 的啟動段才取消(模型下載、選格式);發表後讓 results 迴圈自然結束,停止後的定稿才到得了
            // (beginTask 留著,超時走 cancelPending 才取消)。
            if cancelBegin { beginTask?.cancel(); beginTask = nil }
            cont?.finish()
            if let a {
                let who = isYou ? "你" : "對方"
                Task {
                    do { try await a.finalizeAndFinishThroughEndOfInput() }
                    catch { os_log(.error, "MyParrot live: SpeechAnalyzer finalize 失敗(%{public}@,%{private}@)", who, "\(error)") }   // 二審:不吞、不公開錯誤全文
                }
            }
            if alreadyEnded { onDone() }
        }

        /// 超時兜底(LiveStopDrain 15 秒):results 迴圈沒自然結束 ⇒ 取消整個 begin task、放掉 onDone(drain 已自己觸發)。正常路徑不走這裡。
        func cancelPending() {
            lock.withLockUnchecked { ended = true; onDone = nil }
            beginTask?.cancel(); beginTask = nil
        }

        private func markDone() {
            let h = lock.withLockUnchecked { () -> (() -> Void)? in
                ended = true
                let h = onDone; onDone = nil
                return h
            }
            h?()
        }

        /// Caller must hold `lock` (it reads `analyzerFormat` and mutates `converter`/`converterSource`).
        private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            guard let fmt = analyzerFormat else { return nil }
            if input.format == fmt { return input }
            if converter == nil || converterSource != input.format {
                converter = AVAudioConverter(from: input.format, to: fmt)
                converterSource = input.format
            }
            guard let converter else { return nil }
            let ratio = fmt.sampleRate / input.format.sampleRate
            let cap = AVAudioFrameCount(Double(input.frameLength) * ratio + 16)
            guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return input
            }
            return err == nil ? out : nil
        }
    }
}
