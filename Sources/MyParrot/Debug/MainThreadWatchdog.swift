#if DEBUG
import Foundation
import os

/// PERF-07(#2549,TEST_PLAN Z 節):DEBUG 建置的主執行緒卡頓偵測器。
/// 背景執行緒每 100 ms 丟一個 block 到 main queue,量「丟出去到被執行」的延遲;延遲 >100 ms 算一次 stall、
/// 記 os_log『MyParrot hang』。只量不改任何行為;release 連這個檔都不編。
/// 讀數走 DebugControl `perf stalls|reset|block <ms>`。
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    struct Stats: Sendable {
        var since = Date()
        var epoch = 0             // 二審:reset 前送出的 ping 回來時 epoch 不符就丟,不污染新統計
        var pings = 0
        var stalls = 0            // >100 ms
        var maxMs = 0.0
        var recent: [Double] = []  // 最近 ≤3000 筆延遲(ms),算 p95
        var inflightEpoch: Int?    // 在途 ping 屬於哪個 epoch(二審第二輪:reset 跨越時單一 Bool 分不清新舊 ping)
        var lastStallAt: Date?
    }

    static let pingInterval: TimeInterval = 0.1
    static let stallThresholdMs = 100.0

    private let lock = OSAllocatedUnfairLock(initialState: Stats())
    private let started = OSAllocatedUnfairLock(initialState: false)

    func start() {
        let first = started.withLock { s -> Bool in if s { return false }; s = true; return true }
        guard first else { return }
        let t = Thread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: Self.pingInterval)
                guard let self else { return }
                // 上一個 ping 還沒被執行 ⇒ 不疊加(延遲會由那一個量到)。
                let epoch: Int? = self.lock.withLock { s -> Int? in if s.inflightEpoch != nil { return nil }; s.inflightEpoch = s.epoch; return s.epoch }
                guard let epoch else { continue }
                let sent = Date()
                DispatchQueue.main.async { [weak self] in
                    let ms = Date().timeIntervalSince(sent) * 1000
                    self?.record(ms, epoch: epoch)
                }
            }
        }
        t.name = "MyParrot.MainThreadWatchdog"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func record(_ ms: Double, epoch: Int) {
        let stall = lock.withLock { s -> Bool in
            if s.inflightEpoch == epoch { s.inflightEpoch = nil }   // 只有這個 epoch 的在途 ping 才解除在途旗標
            guard epoch == s.epoch else { return false }           // reset 之前送出的,不算
            s.pings += 1
            s.maxMs = max(s.maxMs, ms)
            s.recent.append(ms); if s.recent.count > 3000 { s.recent.removeFirst(s.recent.count - 3000) }
            guard ms > Self.stallThresholdMs else { return false }
            s.stalls += 1; s.lastStallAt = Date()
            return true
        }
        if stall { os_log(.error, "MyParrot hang: main thread %.0f ms", ms) }
    }

    func reset() {
        lock.withLock { s in
            let next = s.epoch + 1
            s = Stats(); s.epoch = next
        }
    }

    /// DebugControl 用:次數／最大／p95／量測秒數。
    func snapshot() -> [String: Any] {
        let (pings, stalls, maxMs, p95, seconds) = lock.withLock { s -> (Int, Int, Double, Double, Double) in
            let sorted = s.recent.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return (s.pings, s.stalls, s.maxMs, p95, Date().timeIntervalSince(s.since))
        }
        return ["pings": pings, "stalls": stalls, "maxMs": (maxMs * 10).rounded() / 10,
                "p95Ms": (p95 * 10).rounded() / 10, "seconds": (seconds * 10).rounded() / 10,
                "thresholdMs": Self.stallThresholdMs, "intervalMs": Self.pingInterval * 1000]
    }
}
#endif
