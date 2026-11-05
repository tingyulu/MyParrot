import Foundation
import Speech
import AVFoundation
import os

/// Live, on-device transcription of both channels during recording.
/// 對方 (system audio) and 你 (microphone) get separate recognition streams so
/// the chat-bubble pane fills in with the right speaker, live.
///
/// v1.1 TODO: migrate to macOS 26 SpeechAnalyzer for long-form streaming without
/// the SFSpeech ~1-minute window (we auto-restart each stream here as a stopgap).
final class LiveTranscriber: LiveTranscribing, @unchecked Sendable {

    /// Called on the main queue whenever the line list changes.
    var onUpdate: (([TranscriptLine]) -> Void)?

    private var locale = Locale(identifier: "zh-TW")
    private var otherStream: Stream?
    private var youStream: Stream?
    /// TR-29(#2672):行列表與 generation 共用 `LiveLineBuffer`(與另外兩個引擎同一份合併規則);
    /// TR-31(#2676):外層 `LiveLineStore`,`endAudio` 後最後一筆定稿收進已關的那一段、由 `LiveStopDrain` 交回。
    private let store = OSAllocatedUnfairLock(initialState: LiveLineStore())
    private(set) var isActive = false

    func start(locale: Locale) {
        self.locale = locale
        if otherStream != nil || youStream != nil || store.withLock({ $0.isOpen }) { stop(completion: nil) }   // 重入保護:上一段照 stop 收尾
        isActive = false   // 二審第三輪:建好兩個 Stream 才算 active,授權失敗不能留著舊的 true
        let gen = store.withLock { $0.start() }   // TR-29:清上一段、換代;TR-31:標開著
        onUpdate?([])
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    os_log(.error, "MyParrot live(SFSpeech): 語音辨識未授權(status %d),這段沒有即時逐字稿", status.rawValue)
                    return
                }
                // 二審(第二輪):授權回呼可能晚於下一次 start();代數已換＝這次 start 被取代,不建 Stream、不覆蓋新的。
                // TR-31:這一段已經 stop(close 過)也不建——否則 Stream 掛在沒人收尾的段上。
                guard self.store.withLock({ $0.isOpen && $0.generation == gen }) else { return }
                self.otherStream?.finish {}; self.youStream?.finish {}   // 理論上已在 start() 的 stop 收掉;保險
                let o = Stream(isYou: false, locale: self.locale) { [weak self] in self?.commit($0, generation: gen) }
                let y = Stream(isYou: true, locale: self.locale) { [weak self] in self?.commit($0, generation: gen) }
                self.otherStream = o; self.youStream = y
                // 二審第三輪:辨識器不存在／不可用(語言包沒裝、離線模型不支援)⇒ 不能標 active 假裝在轉。
                self.isActive = o.isRunning || y.isRunning
                if !self.isActive { os_log(.error, "MyParrot live(SFSpeech): 辨識器不可用(%{public}@),這段沒有即時逐字稿", self.locale.identifier) }
            }
        }
    }

    func appendSystem(_ buffer: AVAudioPCMBuffer) { otherStream?.append(buffer) }
    func appendMic(_ buffer: AVAudioPCMBuffer) { youStream?.append(buffer) }

    /// TR-31:關掉這一段;每個 Stream `endAudio` 後最後一筆 isFinal／error 到了算收完(各 `arrive` 一次),或超時 ⇒
    /// 在 main 交出完整行列表一次。超時才 cancel 還掛著的辨識 task。
    func stop(completion: (@MainActor ([TranscriptLine]) -> Void)?) {
        isActive = false
        let streams = [otherStream, youStream].compactMap { $0 }
        otherStream = nil; youStream = nil
        guard let gen = store.withLock({ $0.close() }) else {
            if let completion { Task { @MainActor in completion([]) } }
            return
        }
        let store = self.store
        let drain = LiveStopDrain(generation: gen, label: "SFSpeech", expected: streams.count,
                                  take: { store.withLock { $0.takeClosing(gen) } },
                                  onTimeout: { streams.forEach { $0.cancelPending() } },
                                  onDone: completion)
        for s in streams { s.finish { drain.arrive() } }
        drain.activate()
    }

    // Replace the live (non-final) line for a speaker, or append a final one (rules live in LiveLineBuffer).
    private func commit(_ line: TranscriptLine, generation gen: Int) {
        switch store.withLock({ $0.commit(line, generation: gen) }) {
        case .active(let snapshot):
            onUpdate?(snapshot)
        case .closing:
            break   // TR-31:上一段 stop() 後才到的定稿——收進那一段、不上屏,LiveStopDrain 收齊後交回
        case .stale:
            os_log("MyParrot live(SFSpeech): 忽略已收尾那段晚到的行(gen %d,%{public}@)", gen, line.isYou ? "你" : "對方")
        }
    }

    /// One speaker's recognition stream, with auto-restart on the SFSpeech window.
    ///
    /// `@unchecked Sendable` because `request` / `task` / `active` / `streamStart`
    /// are touched from several threads: the AVAudioEngine render (audio I/O)
    /// thread via `append()`, the SFSpeech callback queue via `restart()`, and
    /// @MainActor / stop via `finish()`. Today the render side is single-threaded
    /// (the old tap is fully quiesced before a mic hot-swap installs a new one),
    /// but we serialise every access with `lock` instead of relying on that
    /// lock-free invariant. os_unfair_lock keeps the real-time `append()` path
    /// cheap (uncontended lock/unlock is a few ns) and donates priority.
    private final class Stream: @unchecked Sendable {
        private let isYou: Bool
        private let locale: Locale
        private let onLine: (TranscriptLine) -> Void
        private let recognizer: SFSpeechRecognizer?
        private let lock = OSAllocatedUnfairLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var active = true
        private var streamStart = Date()
        /// TR-31:還沒結束(isFinal／error 還沒到)的 recognitionTask,以 request 為鍵——含 50 秒循環時剛 endAudio、仍在吐最後一筆的舊 task。
        /// finish 後這張表空了才算這一聲道收完;同一個 request 的結束只算一次(二審第二輪:framework 可能 isFinal 後再回 error),
        /// 超時 `cancelPending` 取消表裡**全部** task,不只現任。
        private var pending: [ObjectIdentifier: SFSpeechRecognitionTask?] = [:]
        private var ended = false
        private var onDone: (() -> Void)?

        /// 建好當下辨識器存在且可用、第一輪 request 真的接上了。
        private(set) var isRunning = false

        init(isYou: Bool, locale: Locale, onLine: @escaping (TranscriptLine) -> Void) {
            self.isYou = isYou; self.locale = locale; self.onLine = onLine
            self.recognizer = SFSpeechRecognizer(locale: locale)
            begin()
            isRunning = lock.withLockUnchecked { request != nil }
        }

        private func begin() {
            guard let recognizer, recognizer.isAvailable else { return }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.requiresOnDeviceRecognition = true
            req.shouldReportPartialResults = true
            // 「還 active」與「接上新 request、登進 pending」同一臨界區:finish 插不進中間(二審 TR-31)。
            let accepted = lock.withLockUnchecked { () -> Bool in
                guard active else { return false }
                streamStart = Date()
                request = req
                pending[ObjectIdentifier(req)] = .some(nil)
                return true
            }
            guard accepted else { return }
            // recognitionTask may fire the callback (→ lock) on another queue, so start it without holding the lock.
            let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let line = TranscriptLine(isYou: self.isYou, time: Date(),
                                              text: result.bestTranscription.formattedString,
                                              isFinal: result.isFinal)
                    DispatchQueue.main.async { self.onLine(line) }
                }
                // 二審第三輪:非 final 的 result 同時帶 error 也算這一輪結束,不能留在 pending 等超時。
                if result?.isFinal == true || error != nil { self.taskEnded(req) }
            }
            // 登記 task 給超時取消用;finish 可能已在這之間 endAudio 這個 request(task 仍會自己吐最後一筆、走 taskEnded);
            // 若 cancelPending 已把表清掉(超時),剛建的 task 沒人管 ⇒ 立刻取消(二審第三輪)。
            let orphan = lock.withLockUnchecked { () -> Bool in
                let id = ObjectIdentifier(req)
                guard pending[id] != nil else { return true }
                pending[id] = t
                return false
            }
            if orphan { t.cancel() }
        }

        /// 一輪辨識結束(isFinal 或 error)。只有**現任** request 結束才開下一輪(50 秒循環時舊 task 的最後一筆不再把現任也 endAudio);
        /// 已 finish 且沒有任何 task 還在吐 ⇒ 這一聲道收完(TR-31)。
        private func taskEnded(_ req: SFSpeechAudioBufferRecognitionRequest) {
            let (first, isCurrent, canRestart, done) = lock.withLockUnchecked { () -> (Bool, Bool, Bool, Bool) in
                guard pending.removeValue(forKey: ObjectIdentifier(req)) != nil else { return (false, false, false, false) }   // 同一 request 只算一次
                let cur = request === req
                if cur { request = nil }
                return (true, cur, active, !active && pending.isEmpty)
            }
            guard first else { return }
            if isCurrent { req.endAudio() }
            if isCurrent, canRestart { begin() }
            if done { markDone() }
        }

        /// 50 秒視窗主動循環(從 append 來):endAudio 現任、開下一輪;舊 task 的最後一筆之後走 taskEnded(非現任 ⇒ 只從 pending 移除)。
        private func restart() {
            let req = lock.withLockUnchecked { () -> SFSpeechAudioBufferRecognitionRequest? in
                let r = request; request = nil
                return r
            }
            req?.endAudio()
            begin()
        }

        private func markDone() {
            let h = lock.withLockUnchecked { () -> (() -> Void)? in
                ended = true
                let h = onDone; onDone = nil
                return h
            }
            h?()
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            // SFSpeech window is ~1 min; proactively cycle.
            let needsCycle = lock.withLockUnchecked { Date().timeIntervalSince(streamStart) > 50 && request != nil }
            if needsCycle { restart() }
            let req = lock.withLockUnchecked { request }
            req?.append(buffer)
        }

        /// 停止餵音:`endAudio` 讓辨識把最後一段定稿送出(TR-31 之前這裡 `cancel()`,最後一筆到不了)。
        /// `onDone` 在所有還在吐的 task 都結束(pending 歸 0)時呼叫一次;當下一個都沒有 ⇒ 立刻呼叫。
        func finish(onDone: @escaping () -> Void) {
            let (req, done) = lock.withLockUnchecked { () -> (SFSpeechAudioBufferRecognitionRequest?, Bool) in
                active = false
                let r = request; request = nil
                if pending.isEmpty || ended { ended = true; return (r, true) }
                self.onDone = onDone
                return (r, false)
            }
            req?.endAudio()
            if done { onDone() }
        }

        /// 超時兜底:把還掛著的辨識 task **全部**取消、放掉 onDone(drain 已自己觸發;不放會跟 drain 互相持有)。正常路徑不走這裡。
        func cancelPending() {
            let tasks = lock.withLockUnchecked { () -> [SFSpeechRecognitionTask] in
                let ts = pending.values.compactMap { $0 }
                pending.removeAll()
                ended = true; onDone = nil
                return ts
            }
            tasks.forEach { $0.cancel() }
        }
    }
}
