import Foundation
import os

/// TR-31(#2676):一段即時逐字稿 `stop()` 之後的收尾——等兩聲道(或 N 個在飛的塊)都收完,或超時,
/// 在 **main** 把這一段完整的行列表交出去**恰好一次**。三個即時引擎共用;每次 stop 一個實例。
///
/// 行本身由引擎照舊代 `commit` 進 `LiveLineStore.closing[gen]`;這裡只負責「何時取走、交給誰」。
/// `take` 在 main 執行:引擎的行都是 `DispatchQueue.main.async` 排進 main 再 commit(Apple／SFSpeech)
/// 或先 commit 再回報(Whisper),所以 main 上的 take 一定排在最後一行之後(FIFO)。
/// 超時只是保險(引擎 results 串流沒自然結束時),到點就把已收到的交出去、之後才到的行變 `.stale` 留 log。
final class LiveStopDrain: @unchecked Sendable {
    /// 兩聲道收尾的上限;Apple 的 `finalizeAndFinishThroughEndOfInput` 實測 1～3 秒,15 秒是「掛了」的判準。
    static let defaultTimeout: TimeInterval = 15

    let generation: Int
    private let label: String
    private let lock = OSAllocatedUnfairLock()
    private var join: OnceJoin
    private var timeoutTask: Task<Void, Never>?
    // 觸發後就放掉(二審:Whisper 的 engine → drains → drain → onDone → engine 是個環,靠 onDone 裡移除 drains[gen] 破環;
    // 這裡再放一層保險,觸發過的 drain 不再持有任何回呼)。
    private var take: (@Sendable () -> [TranscriptLine]?)?
    private var onTimeout: (@MainActor () -> Void)?
    private var onDone: (@MainActor ([TranscriptLine]) -> Void)?

    /// - expected: 要等幾方(Apple／SFSpeech＝有啟動的聲道數;Whisper＝在飛的塊數)。0 ⇒ `activate()` 當下就觸發。
    /// - take: 在 main 執行,從引擎的 store 取走這一段(`takeClosing(gen)`)。
    /// - onTimeout: 超時才呼叫(main,在 onDone 之前),給引擎取消還掛著的辨識工作。
    /// - onDone: 在 main 執行一次;nil ＝ 呼叫端不要結果(仍會 take,把 closing 清掉)。
    init(generation: Int, label: String, expected: Int,
         take: @escaping @Sendable () -> [TranscriptLine]?,
         onTimeout: (@MainActor () -> Void)? = nil,
         onDone: (@MainActor ([TranscriptLine]) -> Void)?) {
        self.generation = generation
        self.label = label
        self.join = OnceJoin(expected: expected)
        self.take = take
        self.onTimeout = onTimeout
        self.onDone = onDone
    }

    /// 開始計時;期待數 0 立刻觸發。呼叫端在「各方都已經拿到這個 drain 的引用」之後才呼叫
    /// (各方可能在這之前就 `arrive()` 完了——那樣 join 已 fired,這裡什麼都不做)。
    func activate(timeout: TimeInterval = LiveStopDrain.defaultTimeout) {
        enum Next { case fire, wait, done }
        let next = lock.withLock { () -> Next in
            if join.fired { return .done }
            return join.fireIfComplete() ? .fire : .wait
        }
        switch next {
        case .done: return
        case .fire: fire(timedOut: false)
        case .wait:
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if Task.isCancelled { return }
                self?.timedOut()
            }
            let alreadyFired = lock.withLock { () -> Bool in
                if join.fired { return true }
                timeoutTask = task
                return false
            }
            if alreadyFired { task.cancel() }
        }
    }

    /// 一方收完了。
    func arrive() {
        let fireNow = lock.withLock { join.arrive() }
        if fireNow { fire(timedOut: false) }
    }

    private func timedOut() {
        let fireNow = lock.withLock { join.timeout() }
        if fireNow { fire(timedOut: true) }
    }

    private func fire(timedOut: Bool) {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let t = timeoutTask; timeoutTask = nil
            return t
        }
        task?.cancel()
        let (arrived, expected, take, onTimeout, onDone) = lock.withLock {
            () -> (Int, Int, (@Sendable () -> [TranscriptLine]?)?, (@MainActor () -> Void)?, (@MainActor ([TranscriptLine]) -> Void)?) in
            defer { self.take = nil; self.onTimeout = nil; self.onDone = nil }
            return (join.arrived, join.expected, self.take, self.onTimeout, self.onDone)
        }
        let label = self.label, generation = self.generation
        // 走 DispatchQueue.main(不走 Task{@MainActor}):引擎的行是 DispatchQueue.main.async 排進來的,同一條佇列才有 FIFO 保證。
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if timedOut { onTimeout?() }
                let lines = take?() ?? []
                if timedOut {
                    os_log(.error, "MyParrot live(%{public}@): 停止後收尾超時(gen %d,%d/%d 方收完),先交 %d 行;之後才到的行丟棄",
                           label, generation, arrived, expected, lines.count)
                } else {
                    os_log("MyParrot live(%{public}@): 停止後收尾完成(gen %d,%d 方),交 %d 行", label, generation, expected, lines.count)
                }
                onDone?(lines)
            }
        }
    }
}
