import Foundation

/// GATE-01(TEST_PLAN AA 節,2026-11-05):錄音回放源的純函式——把音檔切成固定秒數的塊、算每塊到點時間、聲道對應、電平。
/// 回放本體(讀檔、計時、丟回呼)在 DEBUG 專用的 `ReplayCapture`;這裡只放決策,不碰 AVFoundation、不碰裝置。
/// 由來:11/04 錄音中打筆記卡頓是裝了 app、錄 60 秒才看得到的問題,而真麥／系統音訊要 TCC、要 Eric 在場;
/// 回放源讓效能閘每個 build 都能自己跑。
public enum ReplayPlan {
    public struct Chunk: Equatable, Sendable {
        /// 起始 frame。
        public var start: Int
        /// frame 數(尾塊可能不足一塊)。
        public var length: Int
        /// 自回放起點算的到點秒數(＝ start ÷ sampleRate)。
        public var due: TimeInterval
        public init(start: Int, length: Int, due: TimeInterval) {
            self.start = start; self.length = length; self.due = due
        }
    }

    /// 切塊:每塊 `chunkSeconds`(預設 0.1 s,接近麥克風 tap 4096 frames @ 48 kHz 的 85 ms);尾塊不足照送;0 frame／壞參數 ⇒ 空。
    public static func chunks(totalFrames: Int, sampleRate: Double, chunkSeconds: Double = 0.1) -> [Chunk] {
        guard totalFrames > 0, sampleRate > 0, sampleRate.isFinite, chunkSeconds > 0, chunkSeconds.isFinite else { return [] }
        let framesPerChunk = (chunkSeconds * sampleRate).rounded()
        // 二審第二輪:兩個有限值相乘仍可能溢位成 inf,Int(inf) 會 trap;public 純函式不能靠「真音檔參數合理」。
        guard framesPerChunk.isFinite, framesPerChunk < Double(Int.max / 2) else { return [] }
        let n = max(1, Int(framesPerChunk))
        var out: [Chunk] = []
        out.reserveCapacity(totalFrames / n + 1)
        var start = 0
        while start < totalFrames {
            let len = min(n, totalFrames - start)
            out.append(Chunk(start: start, length: len, due: Double(start) / sampleRate))
            start += len
        }
        return out
    }

    /// 到點了幾塊:從 `nextIndex` 起、`due <= elapsed` 的連續塊數。timer 晚到就一次補送,節拍以起點時間為準、不漂。
    public static func dueCount(_ chunks: [Chunk], nextIndex: Int, elapsed: TimeInterval) -> Int {
        guard nextIndex >= 0, nextIndex < chunks.count else { return 0 }
        var i = nextIndex
        while i < chunks.count, chunks[i].due <= elapsed { i += 1 }
        return i - nextIndex
    }

    /// 聲道對應:立體聲 ⇒ 左＝對方(system)、右＝你(mic),與 `StereoRecorder` 的寫檔約定同向;
    /// 單聲道 ⇒ 兩邊同一軌(`duplicated`＝true,呼叫端記 log);多聲道取前兩軌;0 ⇒ nil。
    public struct ChannelMap: Equatable, Sendable {
        public var other: Int
        public var you: Int
        public var duplicated: Bool
        public init(other: Int, you: Int, duplicated: Bool) { self.other = other; self.you = you; self.duplicated = duplicated }
    }
    public static func channelMap(channels: Int) -> ChannelMap? {
        switch channels {
        case ..<1: return nil
        case 1: return ChannelMap(other: 0, you: 0, duplicated: true)
        default: return ChannelMap(other: 0, you: 1, duplicated: false)
        }
    }

    /// 電平 0…1,與 `AVAudioPCMBuffer.rmsLevel` 同一條公式(RMS × 4、上限 1),讓回放源的電平環跟真麥一致;非有限值 ⇒ 0。
    public static func level(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for v in samples { sum += v * v }
        let r = (sum / Float(samples.count)).squareRoot() * 4
        return r.isFinite ? min(1, r) : 0
    }
    public static func level(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { level($0) }
    }
}
