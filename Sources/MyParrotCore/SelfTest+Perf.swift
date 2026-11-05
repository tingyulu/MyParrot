import Foundation

/// PERF(TEST_PLAN Z 節,2026-11-04):錄音中 UI 節流的純函式(整秒發布、電平合併、峰值保持、相位)。不碰 UI、不碰引擎。
extension SelfTest {

    /// PERF-01:整秒才發布、兩聲道電平 100 ms 合併、TimelineView 相位。
    static func uiRefreshThrottle() -> Result {
        var fails: [String] = []

        // (a) ElapsedDisplay
        if ElapsedDisplay.shouldPublish(prev: 3.2, next: 3.7) { fails.append("同一秒內不該發布") }
        if !ElapsedDisplay.shouldPublish(prev: 3.9, next: 4.0) { fails.append("跨整秒要發布") }
        if !ElapsedDisplay.shouldPublish(prev: 3.9, next: 4.1) { fails.append("跨整秒(非整點)要發布") }
        if ElapsedDisplay.shouldPublish(prev: 0, next: 0) { fails.append("0→0 不發布") }
        if !ElapsedDisplay.shouldPublish(prev: 10.5, next: 0) { fails.append("歸零要發布") }
        if !ElapsedDisplay.shouldPublish(prev: 5.0, next: 4.99) { fails.append("往回走要發布") }
        if !ElapsedDisplay.shouldPublish(prev: 4.9, next: 4.2) { fails.append("同一秒內往回走也要發布(只看整秒會漏)") }

        // (b) LevelCoalescer
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        var c = LevelCoalescer(window: 0.1)
        if c.feed(.other, level: 0.2, now: t0) != nil { fails.append("第一筆不該發布") }
        if c.feed(.you, level: 0.1, now: t0.addingTimeInterval(0.03)) != nil { fails.append("窗內不該發布") }
        if c.feed(.other, level: 0.5, now: t0.addingTimeInterval(0.06)) != nil { fails.append("窗內第三筆不該發布") }
        guard let b1 = c.feed(.you, level: 0.05, now: t0.addingTimeInterval(0.11)) else {
            fails.append("窗滿後的那一筆要交出 batch")
            return Result(name: "PERF-01 UI 更新節流", passed: false, detail: fails.joined(separator: ";"))
        }
        if b1.other?.peak != 0.5 || b1.other?.buffers != 2 || b1.other?.lastAt != t0.addingTimeInterval(0.06) {
            fails.append("對方軌彙整錯:\(String(describing: b1.other))")
        }
        if b1.you?.peak != 0.1 || b1.you?.buffers != 1 || b1.you?.lastAt != t0.addingTimeInterval(0.03) {
            fails.append("你軌彙整錯:\(String(describing: b1.you))")
        }
        // 觸發發布的那一筆屬於新窗
        guard let b2 = c.feed(.you, level: 0.3, now: t0.addingTimeInterval(0.25)) else {
            fails.append("第二窗滿要交出"); return Result(name: "PERF-01 UI 更新節流", passed: false, detail: fails.joined(separator: ";"))
        }
        if b2.other != nil { fails.append("第二窗沒餵對方軌 ⇒ 應為 nil,不能拿 0 蓋舊值") }
        if b2.you?.peak != 0.05 || b2.you?.buffers != 1 { fails.append("第二窗你軌應只有觸發那一筆 0.05:\(String(describing: b2.you))") }
        let f1 = c.flush()
        if f1?.you?.peak != 0.3 || f1?.you?.buffers != 1 || f1?.other != nil { fails.append("flush 應交出窗內剩的 you=0.3:\(String(describing: f1))") }
        if c.flush() != nil { fails.append("連續 flush 第二次應為 nil") }
        if c.feed(.other, level: 0.9, now: t0.addingTimeInterval(1)) != nil { fails.append("flush 後第一筆重新開窗、不發布") }
        var st = LevelCoalescer(window: 0.1)
        _ = st.feed(.other, level: 0.4, now: t0)
        if st.flushIfStale(now: t0.addingTimeInterval(0.15), olderThan: 0.2) != nil { fails.append("窗還沒超過 olderThan 不該交出") }
        if st.flushIfStale(now: t0.addingTimeInterval(0.25), olderThan: 0.2)?.other?.peak != 0.4 { fails.append("窗開超過 0.2 s 沒下一筆也要交出") }
        if st.flushIfStale(now: t0.addingTimeInterval(1), olderThan: 0.2) != nil { fails.append("交出後再問應為 nil") }
        var nf = LevelCoalescer(window: 0.1)
        _ = nf.feed(.you, level: .nan, now: t0); _ = nf.feed(.you, level: .infinity, now: t0.addingTimeInterval(0.01)); _ = nf.feed(.you, level: -0.5, now: t0.addingTimeInterval(0.02))
        let nfb = nf.flush()
        if nfb?.you?.peak != 0 || nfb?.you?.buffers != 3 { fails.append("NaN／∞／負值當 0、仍算 buffer 數:\(String(describing: nfb))") }
        var z = LevelCoalescer(window: 0)
        _ = z.feed(.other, level: 0.1, now: t0)
        if z.feed(.other, level: 0.2, now: t0.addingTimeInterval(0.001))?.other?.peak != 0.1 { fails.append("窗 0 ⇒ 每一筆之後都交出前一筆") }

        // (b2) MeterPeakHold / MeterSnapshot
        var ph = MeterPeakHold(hold: 1.5)
        ph.update(0.4, now: t0); ph.update(0.2, now: t0.addingTimeInterval(0.5))
        if ph.held != 0.4 { fails.append("1.5 s 內較低的值不該拉下峰值") }
        ph.update(0.6, now: t0.addingTimeInterval(0.6)); if ph.held != 0.6 { fails.append("更高的值立刻取代峰值") }
        ph.update(0.1, now: t0.addingTimeInterval(2.2)); if ph.held != 0.1 { fails.append("超過 1.5 s 峰值要掉下來") }
        var ms = MeterSnapshot()
        ms.update(other: 0.3, you: nil, now: t0); ms.update(other: nil, you: 0.7, now: t0.addingTimeInterval(0.1))
        if ms.other != 0.3 || ms.you != 0.7 || ms.otherPeak.held != 0.3 || ms.youPeak.held != 0.7 { fails.append("快照 nil 聲道不動、兩軌各自保持:\(ms)") }
        ms.reset(); if ms != MeterSnapshot() { fails.append("reset 要歸零") }

        // (c) DecorClock
        let ref = Date(timeIntervalSinceReferenceDate: 0)
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
        if !near(DecorClock.sawtooth(at: ref.addingTimeInterval(0.25), period: 1), 0.25) { fails.append("鋸齒 0.25") }
        if !near(DecorClock.sawtooth(at: ref.addingTimeInterval(1.75), period: 1), 0.75) { fails.append("鋸齒 1.75→0.75") }
        if !near(DecorClock.sawtooth(at: ref.addingTimeInterval(-0.25), period: 1), 0.75) { fails.append("鋸齒負時間要落在 0～1") }
        if !near(DecorClock.sawtooth(at: ref, period: 0), 0) { fails.append("period 0 ⇒ 0") }
        if !near(DecorClock.triangle(at: ref.addingTimeInterval(0.25), period: 1), 0.5) { fails.append("三角 0.25→0.5") }
        if !near(DecorClock.triangle(at: ref.addingTimeInterval(0.5), period: 1), 1) { fails.append("三角 0.5→1") }
        if !near(DecorClock.triangle(at: ref.addingTimeInterval(0.75), period: 1), 0.5) { fails.append("三角 0.75→0.5") }
        if !near(DecorClock.triangle(at: ref.addingTimeInterval(1.0), period: 1), 0) { fails.append("三角 1.0→0") }
        if !DecorClock.on(at: ref.addingTimeInterval(0.1), period: 0.35) { fails.append("方波 0.1 應 on") }
        if DecorClock.on(at: ref.addingTimeInterval(0.4), period: 0.35) { fails.append("方波 0.4 應 off") }
        if !DecorClock.on(at: ref.addingTimeInterval(0.75), period: 0.35) { fails.append("方波 0.75 應 on") }
        if !near(DecorClock.eased(0), 0) || !near(DecorClock.eased(1), 1) || !near(DecorClock.eased(0.5), 0.5) { fails.append("eased 端點與中點") }
        if DecorClock.eased(0.25) >= 0.25 || DecorClock.eased(0.75) <= 0.75 { fails.append("eased 應頭尾慢、中間快") }
        if !near(DecorClock.eased(-1), 0) || !near(DecorClock.eased(2), 1) { fails.append("eased 夾在 0～1") }
        if !near(DecorClock.easeOut(0), 0) || !near(DecorClock.easeOut(1), 1) || !near(DecorClock.easeOut(0.5), 0.75) { fails.append("easeOut 端點與中點(0.5→0.75)") }
        if !near(DecorClock.easeIn(0), 0) || !near(DecorClock.easeIn(1), 1) || !near(DecorClock.easeIn(0.5), 0.25) { fails.append("easeIn 端點與中點(0.5→0.25)") }
        if !near(DecorClock.easeOut(3), 1) || !near(DecorClock.easeIn(-2), 0) { fails.append("easeIn／easeOut 夾在 0～1") }

        return Result(name: "PERF-01 UI 更新節流", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "整秒／歸零／回退發布規則 6 組;電平合併兩窗＋flush＋窗 0;鋸齒／三角／方波／eased 邊界全對" : fails.joined(separator: ";"))
    }
}
