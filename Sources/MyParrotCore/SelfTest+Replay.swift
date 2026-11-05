import Foundation

/// GATE-01(TEST_PLAN AA 節,2026-11-05):回放源純函式——切塊、到點計數、聲道對應、電平。不碰 AVFoundation。
extension SelfTest {

    static func replayPlan() -> Result {
        var fails: [String] = []

        // 切塊:3.25 s @ 48 kHz、0.1 s 一塊 ⇒ 32 塊滿(4800 frames)＋尾塊 2400 frames ＝ 33 塊
        let cs = ReplayPlan.chunks(totalFrames: 156_000, sampleRate: 48_000)
        if cs.count != 33 { fails.append("3.25 s 應切 33 塊,得 \(cs.count)") }
        if cs.first != ReplayPlan.Chunk(start: 0, length: 4800, due: 0) { fails.append("第一塊錯:\(String(describing: cs.first))") }
        if let last = cs.last, last.start != 153_600 || last.length != 2400 || abs(last.due - 3.2) > 1e-9 { fails.append("尾塊錯:\(last)") }
        if cs.map(\.length).reduce(0, +) != 156_000 { fails.append("塊長總和應等於總 frame") }
        if zip(cs, cs.dropFirst()).contains(where: { $0.due >= $1.due }) { fails.append("到點時間要嚴格遞增") }
        if ReplayPlan.chunks(totalFrames: 100, sampleRate: 48_000).count != 1 { fails.append("不足一塊也要送一塊") }
        if !ReplayPlan.chunks(totalFrames: 0, sampleRate: 48_000).isEmpty { fails.append("0 frame 應為空") }
        if !ReplayPlan.chunks(totalFrames: 10, sampleRate: 0).isEmpty { fails.append("取樣率 0 應為空") }
        if !ReplayPlan.chunks(totalFrames: 10, sampleRate: 48_000, chunkSeconds: 0).isEmpty { fails.append("塊長 0 應為空") }
        if !ReplayPlan.chunks(totalFrames: 10, sampleRate: 48_000, chunkSeconds: .infinity).isEmpty { fails.append("塊長 inf 應為空(二審:不可 trap)") }
        if !ReplayPlan.chunks(totalFrames: 10, sampleRate: .nan, chunkSeconds: 0.1).isEmpty { fails.append("取樣率 NaN 應為空") }
        if !ReplayPlan.chunks(totalFrames: 10, sampleRate: 1e200, chunkSeconds: 1e200).isEmpty { fails.append("乘積溢位成 inf 應為空(二審第二輪:不可 trap)") }

        // 到點計數(timer 晚到一次補送、不漂)
        if ReplayPlan.dueCount(cs, nextIndex: 0, elapsed: 0) != 1 { fails.append("t=0 只有第 0 塊到點") }
        if ReplayPlan.dueCount(cs, nextIndex: 0, elapsed: 0.25) != 3 { fails.append("t=0.25 應 3 塊(0／0.1／0.2)") }
        if ReplayPlan.dueCount(cs, nextIndex: 3, elapsed: 0.25) != 0 { fails.append("已送到第 3 塊、t=0.25 ⇒ 0") }
        if ReplayPlan.dueCount(cs, nextIndex: 5, elapsed: 1.0) != 6 { fails.append("晚了一次補送:第 5～10 塊共 6 塊") }
        if ReplayPlan.dueCount(cs, nextIndex: 33, elapsed: 99) != 0 { fails.append("播完 ⇒ 0") }
        if ReplayPlan.dueCount(cs, nextIndex: -1, elapsed: 99) != 0 { fails.append("負索引 ⇒ 0") }
        if ReplayPlan.dueCount(cs, nextIndex: 0, elapsed: 99) != 33 { fails.append("elapsed 超過全長 ⇒ 全部") }

        // 聲道對應:左對方、右你;單聲道同軌;多聲道取前兩軌
        if ReplayPlan.channelMap(channels: 0) != nil { fails.append("0 聲道應 nil") }
        if ReplayPlan.channelMap(channels: 1) != ReplayPlan.ChannelMap(other: 0, you: 0, duplicated: true) { fails.append("單聲道兩邊同軌＋duplicated") }
        if ReplayPlan.channelMap(channels: 2) != ReplayPlan.ChannelMap(other: 0, you: 1, duplicated: false) { fails.append("立體聲左對方右你") }
        if ReplayPlan.channelMap(channels: 6) != ReplayPlan.ChannelMap(other: 0, you: 1, duplicated: false) { fails.append("多聲道取前兩軌") }

        // 電平:與 rmsLevel 同公式(RMS × 4,上限 1),非有限值 ⇒ 0
        if ReplayPlan.level([Float]()) != 0 { fails.append("空 ⇒ 0") }
        if ReplayPlan.level([Float](repeating: 0, count: 480)) != 0 { fails.append("靜音 ⇒ 0") }
        let l = ReplayPlan.level([Float](repeating: 0.1, count: 480))
        if abs(l - 0.4) > 1e-5 { fails.append("0.1 定值 RMS 0.1×4＝0.4,得 \(l)") }
        if ReplayPlan.level([Float](repeating: 0.9, count: 480)) != 1 { fails.append("上限 1") }
        if ReplayPlan.level([Float.nan, 0.1]) != 0 { fails.append("非有限值 ⇒ 0") }
        let sq = (0..<480).map { $0 % 2 == 0 ? Float(0.5) : Float(-0.5) }
        if ReplayPlan.level(sq) != 1 { fails.append("±0.5 方波 RMS 0.5×4＝2 ⇒ 上限 1") }

        return Result(name: "GATE-01 回放源純函式", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "切 33 塊／到點計數／聲道對應／電平公式" : fails.joined(separator: ";"))
    }
}
