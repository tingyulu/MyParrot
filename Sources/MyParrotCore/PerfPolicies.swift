import Foundation

// PERF(TEST_PLAN Z 節;Eric 2026-11-04 A1 B1 C1):錄音中 UI 更新節流的純函式。
// 由來:11/04 會中打筆記卡——6 個 repeatForever 動畫＋0.25 s elapsed＋約 24 Hz 電平讓 SwiftUI 每幀整窗重排;
// (B1 的 audio_ctx 縮窗真路徑試過不可行,已拿掉,見 TEST_REPORT「11/04 PERF」。)這裡只放決策,不碰 UI、不碰引擎。

/// PERF-01(a):計時顯示到秒,整秒沒變就不發布 `elapsed`(ticker 仍 0.25 s 跑看門狗)。
public enum ElapsedDisplay {
    /// `prev`＝上次發布的值、`next`＝這次算出來的值。回 true ＝ 要發布。
    /// 整秒變了要發;往回走(歸零、暫停回到 accumulated)也要發,免得畫面停在舊秒數。
    public static func shouldPublish(prev: TimeInterval, next: TimeInterval) -> Bool {
        if next < prev { return true }
        return floor(prev) != floor(next)
    }
}

/// PERF-01(b):兩聲道電平合併——窗內每聲道取最大值、記最後一筆時間與筆數;窗滿後下一筆進來時一次交出。
/// 值型別、純函式,呼叫端自己配鎖(音訊回呼在兩條不同執行緒)。
public struct LevelCoalescer: Sendable, Equatable {
    public enum Channel: Sendable, Equatable { case other, you }

    /// 一個聲道在這一窗的彙整。
    public struct ChannelStat: Sendable, Equatable {
        public var peak: Float
        public var lastAt: Date
        public var buffers: Int
    }

    /// 一次發布:沒餵過的聲道是 nil(不能拿 0 蓋掉舊值)。
    public struct Batch: Sendable, Equatable {
        public var other: ChannelStat?
        public var you: ChannelStat?
    }

    public let window: TimeInterval
    private var windowStart: Date?
    private var other: ChannelStat?
    private var you: ChannelStat?

    public init(window: TimeInterval = 0.1) {
        self.window = max(0, window)
    }

    /// 餵一筆。回 nil ＝ 還在窗內(已累計);回 Batch ＝ 窗滿,交出彙整並以這一筆開新窗(這一筆算進新窗)。
    public mutating func feed(_ ch: Channel, level: Float, now: Date) -> Batch? {
        var out: Batch?
        if let start = windowStart, now.timeIntervalSince(start) >= window {
            out = Batch(other: other, you: you)
            other = nil; you = nil
            windowStart = now
        } else if windowStart == nil {
            windowStart = now
        }
        switch ch {
        case .other: other = Self.merge(other, level: level, now: now)
        case .you: you = Self.merge(you, level: level, now: now)
        }
        return out
    }

    /// 二審:buffer 停了(裝置死掉)最後一窗沒有「下一筆」來觸發 ⇒ ticker 每 0.25 s 問一次,窗開著超過 `olderThan` 就交出(狀態歸零)。
    public mutating func flushIfStale(now: Date, olderThan: TimeInterval) -> Batch? {
        guard let start = windowStart, now.timeIntervalSince(start) >= olderThan else { return nil }
        return flush()
    }

    /// 停錄／換裝置時把窗內剩的交出來(沒有就 nil),狀態歸零。
    public mutating func flush() -> Batch? {
        defer { windowStart = nil; other = nil; you = nil }
        guard other != nil || you != nil else { return nil }
        return Batch(other: other, you: you)
    }

    private static func merge(_ s: ChannelStat?, level raw: Float, now: Date) -> ChannelStat {
        let level = raw.isFinite ? max(0, raw) : 0   // 二審:NaN／∞ 不能進 max 與峰值保持,當 0(buffer 仍算有到)
        guard var s else { return ChannelStat(peak: level, lastAt: now, buffers: 1) }
        s.peak = max(s.peak, level); s.lastAt = max(s.lastAt, now); s.buffers += 1
        return s
    }
}

/// PERF-03:電平峰值保持(原 DialView.PeakHold,搬進 Core 改成以電平值保持;段數映射單調,行為同):
/// 比目前高的峰值保持 `hold` 秒再掉下來。
public struct MeterPeakHold: Sendable, Equatable {
    public private(set) var held: Float = 0
    public private(set) var since: Date = .distantPast
    public let hold: TimeInterval
    public init(hold: TimeInterval = 1.5) { self.hold = hold }
    public mutating func update(_ level: Float, now: Date) {
        if level >= held || now.timeIntervalSince(since) > hold {
            held = level
            since = now
        }
    }
}

/// PERF-03:圓盤電平環讀的快照——不是 @Observable 屬性,由 10 Hz 時鐘的 tick 去 `peek`,電平更新本身不再觸發 SwiftUI pass。
public struct MeterSnapshot: Sendable, Equatable {
    public var other: Float = 0
    public var you: Float = 0
    public var otherPeak = MeterPeakHold()
    public var youPeak = MeterPeakHold()
    public init() {}
    /// nil ＝ 這一批沒有該聲道,不動它。
    public mutating func update(other o: Float?, you y: Float?, now: Date) {
        if let o { other = o; otherPeak.update(o, now: now) }
        if let y { you = y; youPeak.update(y, now: now) }
    }
    public mutating func reset() { self = MeterSnapshot() }
}

/// PERF-01(c):給 `TimelineView(.periodic)` 用的相位——裝飾動畫不再 `repeatForever`,改每個 tick 查表。
public enum DecorClock {
    /// 0～1 鋸齒(單向);`period` ≤0 ⇒ 0。
    public static func sawtooth(at date: Date, period: TimeInterval) -> Double {
        guard period > 0 else { return 0 }
        let t = date.timeIntervalSinceReferenceDate
        let r = t.truncatingRemainder(dividingBy: period)
        return (r < 0 ? r + period : r) / period
    }

    /// 0→1→0 三角波(autoreverse);一個完整往復＝`period` 秒(與 `.repeatForever(autoreverses: true)` 的 2×duration 對齊由呼叫端決定)。
    public static func triangle(at date: Date, period: TimeInterval) -> Double {
        let s = sawtooth(at: date, period: period)
        return 1 - abs(2 * s - 1)
    }

    /// 方波:每 `period` 秒切一次 true／false(換幀用,取代 0.35 s 的 `Int(t / 0.35) % 2 == 0`)。
    public static func on(at date: Date, period: TimeInterval) -> Bool {
        guard period > 0 else { return true }
        let n = (date.timeIntervalSinceReferenceDate / period).rounded(.down)
        return Int(n) % 2 == 0
    }

    /// ease-in-out(sine)把三角波修圓,免得 10 Hz 階梯看起來像卡。
    public static func eased(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return 0.5 - 0.5 * cos(c * .pi)
    }

    /// ease-out(二次):聲波擴散用,前快後慢(對齊舊 `.easeOut(duration: 1.7)`)。
    public static func easeOut(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return 1 - (1 - c) * (1 - c)
    }

    /// ease-in(二次):音符上飄用,前慢後快(對齊舊 `.easeIn(duration: 1.25)`)。
    public static func easeIn(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c
    }
}
