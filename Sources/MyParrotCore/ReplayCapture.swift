#if DEBUG
import Foundation
import AVFoundation
import os

/// GATE-02(TEST_PLAN AA 節,2026-11-05):DEBUG 專用的錄音回放源。讀一個音檔,左聲道當對方(system)、右聲道當你(mic),
/// 在背景佇列按真實節拍每 100 ms 丟一塊到跟 `SystemAudioCapture`／`MicCapture` 同形狀的 `onBuffer`／`onLevel` 回呼;
/// 錄音寫檔、即時逐字稿、電平合併、看門狗、租約全走原路,只有「音從哪來」換掉。不碰任何裝置 ⇒ 不需要 TCC、
/// 不受測試 build 路徑影響。只在 DEBUG 編譯,release 二進位沒有這個類別(整檔 `#if DEBUG`)。
///
/// 執行緒模型:控制(start／pause／resume)與 tick 都在私有序列佇列 `queue`;`AVAudioFile` 只在這條佇列上讀;
/// 回呼在佇列上被呼叫(跟真裝置一樣是「某條音訊執行緒」,不是 main)。`stop()` 同步翻旗標再同步等佇列排空 ⇒
/// 回來後保證沒有回呼在飛,呼叫端才可以收 recorder(二審:原本 async stop 會跟 recorder.stop 競爭)。
/// 節拍用單調時鐘(`DispatchTime`),不受校時影響;timer 晚到時每個 tick 最多補送 `maxChunksPerTick` 塊、落後量記進
/// `maxLateMs` 讓閘判(二審:一口氣灌入會把「被測 app 卡住」變成下游的突發負載,量到的是補送尖峰不是穩態)。
/// 讀檔失敗、短讀、配置失敗都是終止性錯誤:停止回放、`onError` 一次、`status.error` 留著給閘判紅。
final class ReplayCapture: @unchecked Sendable {
    var onOtherBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onOtherLevel: ((Float) -> Void)?
    var onYouBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onYouLevel: ((Float) -> Void)?
    /// 終止性錯誤(讀檔失敗／短讀／配置失敗),在回放佇列上呼叫一次;接收端自己 hop 到 main。
    var onError: (@Sendable (String) -> Void)?

    struct Status: Sendable {
        var finished: Bool
        var error: String?
        var sentChunks: Int
        var totalChunks: Int
        var maxLateMs: Double
    }

    let url: URL
    let sampleRate: Double
    let channels: Int
    let totalFrames: Int
    var duration: TimeInterval { Double(totalFrames) / sampleRate }
    let map: ReplayPlan.ChannelMap
    /// 每個 tick 最多補送幾塊(timer 晚到時逐步追上)。tick 50 ms、塊 100 ms ⇒ 正常一個 tick 0～1 塊;2 塊＝一次最多追 100 ms,
    /// 落後更多就分幾個 tick 追、落後量留在 `maxLateMs` 讓閘判(二審第二輪:3 塊＝一次灌 300 ms 仍是突發)。
    static let maxChunksPerTick = 2

    private let file: AVAudioFile
    private let monoFormat: AVAudioFormat
    private let chunks: [ReplayPlan.Chunk]
    private let queue = DispatchQueue(label: "tw.uncle.MyParrot.replay", qos: .userInitiated)

    private struct Shared: Sendable {
        var stopped = false
        var finished = false
        var error: String?
        var sentChunks = 0
        var maxLateMs = 0.0
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    var status: Status {
        shared.withLock { Status(finished: $0.finished, error: $0.error, sentChunks: $0.sentChunks,
                                 totalChunks: chunks.count, maxLateMs: $0.maxLateMs) }
    }
    /// 播完(所有塊都送出去)。之後兩軌就是靜音,看門狗會照常報無聲——這是預期。
    var isFinished: Bool { shared.withLock { $0.finished } }
    private var isStopped: Bool { shared.withLock { $0.stopped } }

    // MARK: 以下全部 queue-confined
    private var timer: DispatchSourceTimer?
    private var nextIndex = 0
    private var startedAt: DispatchTime?
    private var pausedAt: DispatchTime?
    private var pausedTotal: TimeInterval = 0

    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        sampleRate = file.processingFormat.sampleRate
        channels = Int(file.processingFormat.channelCount)
        totalFrames = Int(file.length)
        guard let m = ReplayPlan.channelMap(channels: channels), sampleRate > 0, totalFrames > 0 else {
            throw "回放檔不可用(\(channels) ch @ \(Int(sampleRate)) Hz, \(totalFrames) frames):\(url.lastPathComponent)"
        }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw "回放檔單聲道格式建不起來(\(Int(sampleRate)) Hz)"
        }
        map = m
        monoFormat = mono
        chunks = ReplayPlan.chunks(totalFrames: totalFrames, sampleRate: sampleRate)
        if m.duplicated {
            os_log("MyParrot replay: %{public}@ 是單聲道,對方軌與你軌同一份", url.lastPathComponent)
        }
    }

    /// 開始回放(非阻塞)。timer 每 50 ms 看一次哪些塊到點。
    func start() {
        queue.async {
            guard self.startedAt == nil, !self.isStopped else { return }
            self.startedAt = .now()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
            os_log("MyParrot replay: 開始 %{public}@ (%.1f s, %d ch @ %.0f Hz, %d 塊)",
                   self.url.lastPathComponent, self.duration, self.channels, self.sampleRate, self.chunks.count)
        }
    }

    /// 暫停:不送塊、進度停在原地(恢復時從下一塊續播,不跳格)。**同步**:回來後保證沒有塊還在送——
    /// 呼叫端接著把 recorder 設成暫停,才不會有「tick 已送、recorder 已丟、恢復後不重送」的缺口(二審第二輪)。
    func pause() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            guard self.startedAt != nil, self.pausedAt == nil, !self.isStopped else { return }
            self.pausedAt = .now()
        }
    }

    /// 恢復:**同步**(跟 pause 對稱,二審第三輪)——回來後 pausedTotal 已更新、下一個 tick 就會續播;呼叫端接著才解除 recorder 暫停。
    func resume() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            guard let p = self.pausedAt else { return }
            self.pausedTotal += Self.seconds(from: p, to: .now())
            self.pausedAt = nil
        }
    }

    /// 停止:同步翻旗標(進行中的 tick 看到就不再丟),再同步等佇列排空;回來後沒有回呼在飛。可重入。
    /// 🚫 不要從回放佇列自己呼叫(會死鎖);onError 的接收端要先 hop 到 main。
    func stop() {
        dispatchPrecondition(condition: .notOnQueue(queue))   // 回呼路徑不得同步回 main 再呼叫這裡(契約,見檔頭)
        shared.withLock { $0.stopped = true }
        queue.sync {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private static func seconds(from a: DispatchTime, to b: DispatchTime) -> TimeInterval {
        Double(b.uptimeNanoseconds &- a.uptimeNanoseconds) / 1_000_000_000
    }

    private func tick() {
        guard let startedAt, !isStopped, pausedAt == nil else { return }
        let elapsed = Self.seconds(from: startedAt, to: .now()) - pausedTotal
        let due = ReplayPlan.dueCount(chunks, nextIndex: nextIndex, elapsed: elapsed)
        guard due > 0 else { return }
        let lateMs = (elapsed - chunks[nextIndex].due) * 1000
        shared.withLock { if lateMs > $0.maxLateMs { $0.maxLateMs = lateMs } }
        let n = min(due, Self.maxChunksPerTick)
        for i in nextIndex..<(nextIndex + n) {
            if isStopped { return }
            guard emit(chunks[i]) else { return }   // emit 失敗已 fail(),不再前進
            nextIndex = i + 1
            shared.withLock { $0.sentChunks = i + 1 }
        }
        if nextIndex >= chunks.count {
            shared.withLock { $0.finished = true }
            timer?.cancel(); timer = nil
            os_log("MyParrot replay: 播完 %{public}@ (%.1f s, 最大落後 %.0f ms)", url.lastPathComponent, duration, status.maxLateMs)
        }
    }

    private func fail(_ message: String) {
        shared.withLock { $0.error = message; $0.stopped = true }
        timer?.cancel(); timer = nil
        os_log(.error, "MyParrot replay: %{public}@", message)
        onError?(message)
    }

    /// 讀一塊、拆成兩個單聲道 buffer(格式＝檔案取樣率、Float32 非交錯,下游 `MonoDownconverter` 跟真麥一樣自己轉 48 kHz)、
    /// 算電平、丟回呼。任何一步失敗 ⇒ fail()、回 false。
    private func emit(_ c: ReplayPlan.Chunk) -> Bool {
        guard let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(c.length)) else {
            fail("配置 \(c.length) frames 的讀取 buffer 失敗(frame \(c.start))"); return false
        }
        file.framePosition = AVAudioFramePosition(c.start)
        do {
            try file.read(into: src, frameCount: AVAudioFrameCount(c.length))
        } catch {
            fail("讀檔失敗 frame \(c.start):\(error)"); return false
        }
        guard Int(src.frameLength) == c.length else {
            fail("短讀 frame \(c.start):要 \(c.length) 得 \(src.frameLength)"); return false
        }
        guard let data = src.floatChannelData else { fail("讀到的 buffer 沒有 float 資料(frame \(c.start))"); return false }
        let n = Int(src.frameLength)
        func mono(_ ch: Int) -> AVAudioPCMBuffer? {
            guard ch < channels, let b = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: src.frameLength),
                  let dst = b.floatChannelData else { return nil }
            b.frameLength = src.frameLength
            dst[0].update(from: data[ch], count: n)
            return b
        }
        guard let o = mono(map.other), let y = mono(map.you) else {
            fail("配置單聲道 buffer 失敗(frame \(c.start))"); return false
        }
        onOtherLevel?(ReplayPlan.level(UnsafeBufferPointer(start: data[map.other], count: n)))
        onOtherBuffer?(o)
        onYouLevel?(ReplayPlan.level(UnsafeBufferPointer(start: data[map.you], count: n)))
        onYouBuffer?(y)
        return true
    }
}
#endif
