import Foundation
import AVFoundation

/// Lightweight self-tests that run under plain Command Line Tools (no Xcode /
/// XCTest required). Exercised by the `MyParrotSelfTest` executable.
public enum SelfTest {

    public struct Result: Sendable {
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    public static func run() -> [Result] {
        [
            fileNameFormat(),
            fileNameFallback(),
            sampleQueueFIFO(),
            drainNoClick(),
            monoResample(),
            stereoSeparation(),
            deviceEnumeration(),
            gainScaling(),
            m4aExport(),
            srtFormat(),
            echoCancel(),
            aecNoEchoGate()
        ]
    }

    // MARK: - Cases
    // 內部可見(非 private)讓 Swift Testing 套件能逐案例呼叫,避免重複測試邏輯。

    static func fileNameFormat() -> Result {
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 22; c.hour = 14; c.minute = 30
        let date = Calendar.current.date(from: c)!
        let name = Recording.fileName(date: date, title: "客戶會議-CMoney")
        let want = "2026-06-22 1430 客戶會議-CMoney.caf"
        return Result(name: "檔名範本 日期+時間+會議名", passed: name == want,
                      detail: name == want ? name : "得到 \(name)")
    }

    static func fileNameFallback() -> Result {
        let name = Recording.fileName(date: Date(), title: "")
        return Result(name: "空標題 fallback → 錄音", passed: name.hasSuffix("錄音.caf"), detail: name)
    }

    static func sampleQueueFIFO() -> Result {
        let q = SampleQueue()
        q.append([1, 2, 3])
        let a = q.drain(2)           // [1,2]
        let b = q.drain(3)           // [3, 1.5, 0] — pad 從最後真樣本淡出(AUD-29,非硬跳 0)
        let c = q.drain(2)           // [0,0] — 持續飢餓時維持純靜音
        let ok = a == [1, 2] && b.count == 3 && b[0] == 3 && abs(b[1] - 1.5) < 1e-4 && b[2] == 0 && c == [0, 0]
        return Result(name: "SampleQueue FIFO + 靜音補齊(pad 淡出)", passed: ok,
                      detail: ok ? "" : "a=\(a) b=\(b) c=\(c)")
    }

    // AUD-29 / BUG-19:補零接縫 ramp + min 抽取(錄音中不再把零插進連續語音)。
    // ① SampleQueue 進/出 padding 的邊界必須是 ≤rampLength 的線性斜坡(無硬階梯);
    // ② StereoRecorder 兩側都有料時以共同長度抽取 → 檔案中段不得出現全零縫
    //    (舊 max() 行為在 23 分實錄留下 2,171 個微零縫,每個=一次 click)。
    static func drainNoClick() -> Result {
        // ① ramp 邊界:1000 個 0.8 → drain(1240) 尾端 240 pad 淡出;再進料驗淡入。
        let q = SampleQueue()
        q.append([Float](repeating: 0.8, count: 1_000))
        let out = q.drain(1_240)
        var maxStep: Float = 0
        for i in 998..<1_239 { maxStep = max(maxStep, abs(out[i + 1] - out[i])) }
        let fadeOutOK = out[1_239] == 0 && maxStep < 0.02   // 0.8/240≈0.0033;硬跳會是 0.8
        q.append([Float](repeating: 0.8, count: 500))
        let resumed = q.drain(500)
        let fadeInOK = resumed[0] == 0 && abs(resumed[239] - 0.8 * 239 / 240) < 1e-3 && resumed[499] == 0.8
        // ② min 抽取:雙側**等速率**但節奏錯開(mic 0.1s 小塊、system 0.2s 大塊,
        //    模擬三時鐘相位差的抖動)→ 檔案中段不得有任何全零樣本(舊 max() 行為
        //    每 tick 都會把零塞進慢側)。頭(pre-pad+淡入)尾(stop flush pad)排除。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_noclick_\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        var interiorZeros = -1
        var window = 0
        do {
            let rec = StereoRecorder()
            try rec.start(url: url)
            for i in 0..<12 {
                rec.feedMic(makeMono(48_000, 4_800, 0.5))                    // 每 0.1s
                if i % 2 == 0 { rec.feedSystem(makeMono(48_000, 9_600, 0.5)) } // 每 0.2s,等速率
                Thread.sleep(forTimeInterval: 0.1)
            }
            Thread.sleep(forTimeInterval: 0.25)
            rec.stop()
            let file = try AVAudioFile(forReading: url)
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            let lo = 8_000, hi = n - 12_000    // 排除頭部 pre-pad/淡入與尾部 flush pad
            window = hi - lo
            var zeros = 0
            if let ch = buf.floatChannelData, window > 10_000 {
                for i in lo..<hi where ch[0][i] == 0 || ch[1][i] == 0 { zeros += 1 }
            }
            interiorZeros = window > 10_000 ? zeros : -1   // 檔案太短=測試環境異常,判 fail
        } catch {
            return Result(name: "AUD-29 補零接縫 ramp + min 抽取", passed: false, detail: "\(error)")
        }
        let ok = fadeOutOK && fadeInOK && interiorZeros == 0
        return Result(name: "AUD-29 補零接縫 ramp + min 抽取", passed: ok,
                      detail: String(format: "pad最大階梯=%.4f(<0.02) 淡入首=%.2f 中段全零樣本=%d(要 0,檢查窗 %d)",
                                     maxStep, resumed.first ?? -1, interiorZeros, window))
    }

    static func monoResample() -> Result {
        let conv = MonoDownconverter(sampleRate: 48_000)
        let out = conv.convert(makeMono(48_000 / 2, 2_400, 0.5)) // 0.1s @ 24k
        let ok = out.count > 4_000 && out.count < 5_200          // ~doubles to 48k
        return Result(name: "24k→48k 重採樣", passed: ok, detail: "\(out.count) 取樣")
    }

    static func stereoSeparation() -> Result {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_selftest_\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let rec = StereoRecorder()
            try rec.start(url: url)
            for _ in 0..<5 {
                rec.feedSystem(makeMono(48_000, 4_800, 0.6))   // 對方 → 左,有訊號
                rec.feedMic(makeMono(48_000, 4_800, 0.0))      // 你 → 右,靜音
                Thread.sleep(forTimeInterval: 0.12)
            }
            Thread.sleep(forTimeInterval: 0.3)
            rec.stop()

            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.channelCount == 2 else {
                return Result(name: "立體聲分軌(對方左／你右)", passed: false, detail: "非立體聲")
            }
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            let l = rms(buf, 0), r = rms(buf, 1)
            let ok = l > 0.1 && r < 0.05 && l > r * 5
            return Result(name: "立體聲分軌(對方左／你右)", passed: ok,
                          detail: String(format: "左RMS=%.3f 右RMS=%.3f", l, r))
        } catch {
            return Result(name: "立體聲分軌(對方左／你右)", passed: false, detail: "\(error)")
        }
    }

    // 設定:麥克風裝置列舉(設定面板的裝置下拉資料來源)
    static func deviceEnumeration() -> Result {
        let devices = AudioDevices.inputDevices()
        let names = devices.map { d -> String in
            let tag = d.isBluetooth ? "[藍牙]" : d.isContinuityWireless ? "[Continuity無線]" : d.isContinuityWired ? "[Continuity有線]" : d.isBuiltIn ? "[內建]" : ""
            return d.name + tag
        }.joined(separator: ", ")
        return Result(name: "設定·麥克風裝置列舉(含 transport)", passed: !devices.isEmpty,
                      detail: devices.isEmpty ? "找不到輸入裝置" : "\(devices.count) 個:\(names)")
    }

    // 設定:靈敏度增益(滑桿 0.5–2.0×)+ 軟限幅防破音
    static func gainScaling() -> Result {
        // 線性區:0.25 ×2 = 0.5(未到 0.9 knee,不被壓)
        let lin = makeMono(48_000, 100, 0.25); lin.scale(by: 2.0)
        let l = lin.floatChannelData![0][0]
        // 限幅區:0.9 ×2 = 1.8 必須被壓在 ±1 內(不破音),且仍 > knee
        let loud = makeMono(48_000, 100, 0.9); loud.scale(by: 2.0)
        let c = loud.floatChannelData![0][0]
        let ok = abs(l - 0.5) < 0.0001 && c <= 1.0 && c > 0.9
        return Result(name: "設定·靈敏度增益 ×2 + 軟限幅", passed: ok,
                      detail: String(format: "0.25→%.3f(線性) 0.9×2→%.3f(限幅≤1)", l, c))
    }

    // 停止錄音後 CAF→m4a 自動匯出(app 用的 AVAssetExportSession 路徑)
    static func m4aExport() -> Result {
        let tmp = FileManager.default.temporaryDirectory
        let caf = tmp.appendingPathComponent("mp_exp_\(UUID().uuidString).caf")
        let m4a = caf.deletingPathExtension().appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: caf); try? FileManager.default.removeItem(at: m4a) }
        do {
            let rec = StereoRecorder()
            try rec.start(url: caf)
            for _ in 0..<5 {
                rec.feedSystem(makeMono(48_000, 4_800, 0.5))
                rec.feedMic(makeMono(48_000, 4_800, 0.3))
                Thread.sleep(forTimeInterval: 0.12)
            }
            Thread.sleep(forTimeInterval: 0.3)
            rec.stop()

            let sem = DispatchSemaphore(value: 0)
            let box = ErrorBox()
            Task { do { try await AudioExport.toM4A(from: caf, to: m4a) } catch { box.error = error }; sem.signal() }
            sem.wait()
            if let e = box.error { return Result(name: "CAF→m4a 匯出", passed: false, detail: "\(e)") }

            let cafSize = (try FileManager.default.attributesOfItem(atPath: caf.path)[.size] as? Int) ?? 0
            let m4aSize = (try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int) ?? 0
            let valid = (try? AVAudioFile(forReading: m4a)) != nil
            let ok = valid && m4aSize > 0 && m4aSize < cafSize
            return Result(name: "CAF→m4a 匯出(更小且可讀)", passed: ok,
                          detail: "caf=\(cafSize/1024)KB → m4a=\(m4aSize/1024)KB")
        } catch {
            return Result(name: "CAF→m4a 匯出", passed: false, detail: "\(error)")
        }
    }

    // SRT 輸出:時間碼格式、講者前綴、無 duration 時補尾(TR-12/13)
    static func srtFormat() -> Result {
        let lines = [
            TranscriptLine(isYou: false, time: Date(), text: "你好", isFinal: true, start: 0, duration: 1.5),
            TranscriptLine(isYou: true, time: Date(), text: "測試", isFinal: true, start: 2.0, duration: 0)
        ]
        let srt = SRT.make(from: lines)
        let ok = srt.contains("1\n00:00:00,000 --> 00:00:01,500\n對方: 你好")
              && srt.contains("2\n00:00:02,000 --> ")
              && srt.contains("你: 測試")
        return Result(name: "SRT 時間碼+講者格式", passed: ok, detail: ok ? "" : srt)
    }

    private final class ErrorBox: @unchecked Sendable { var error: Error? }

    // AUD-16/23 合成驗證 Path A「先對齊再消」:echo = 0.35·ref[i-D],D=100ms(遠超
    // 濾波器,須先估延遲對齊才消得掉;舊版用 64 樣本/1.3ms 太短=假過關)。
    // 流程:DelayEstimator 估 D → 平移對齊 → EchoCanceller 消 → 驗回音衰減+人聲保留。
    static func echoCancel() -> Result {
        let n = 48_000, d = 4_800           // 1s @48k,回音延遲 100ms
        var seed: UInt32 = 12_345
        func rnd() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        var ref = [Float](repeating: 0, count: n), echo = [Float](repeating: 0, count: n)
        var voice = [Float](repeating: 0, count: n), near = [Float](repeating: 0, count: n)
        for i in 0..<n { ref[i] = rnd() * 0.5 }
        for i in d..<n { echo[i] = 0.35 * ref[i - d] }           // speaker→mic echo @100ms
        // 你 silent first half (對方 alone → filter converges), then double-talk.
        for i in (n / 2)..<n { voice[i] = 0.25 * sinf(2 * Float.pi * 1000 * Float(i) / 48_000) }
        for i in 0..<n { near[i] = echo[i] + voice[i] }

        // 1) 估 bulk delay
        let (estD, peak) = DelayEstimator.estimate(near: near, ref: ref, maxLag: 12_000)
        let delayOK = abs(estD - d) <= 64 && peak > 0.2
        // 2) 平移對齊(留 5ms guard)再消
        let shift = max(0, estD - 240)
        var aligned = [Float](repeating: 0, count: n)
        for i in 0..<n { let j = i - shift; if j >= 0 { aligned[i] = ref[j] } }
        let out = EchoCanceller(taps: 2_048, mu: 0.3, doubleTalkThreshold: 0.5, holdSamples: 2_400).process(near: near, ref: aligned)

        func atten(_ lo: Int, _ hi: Int) -> Float {
            var resid: Float = 0, orig: Float = 0
            for i in lo..<hi { let r = out[i] - voice[i]; resid += r * r; orig += echo[i] * echo[i] }
            return 10 * log10f(max(orig, 1e-12) / max(resid, 1e-12))
        }
        let a2 = atten(n / 2, n)                  // double-talk region
        var vpow: Float = 0, opow: Float = 0
        for i in (n / 2)..<n { vpow += voice[i] * voice[i]; opow += out[i] * out[i] }
        let voiceKept = opow / max(vpow, 1e-12)
        let ok = delayOK && a2 >= 12 && voiceKept > 0.5 && voiceKept < 2.0
        return Result(name: "回音消除:大延遲對齊+NLMS(合成)", passed: ok,
                      detail: String(format: "估延遲 %d(真 %d)相關%.2f / 雙講衰減 %.1f dB,人聲保留 %.2f×", estD, d, peak, a2, voiceKept))
    }

    // AUD-25 無回音 gate:near = 純人聲(與 ref 不相關、無喇叭回音)→ 左右軌相關度
    // 低於門檻 → 離線 AEC 會略過、不傷人聲(戴耳機情境)。
    static func aecNoEchoGate() -> Result {
        let n = 48_000
        var seed: UInt32 = 777
        func rnd() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        var ref = [Float](repeating: 0, count: n), near = [Float](repeating: 0, count: n)
        for i in 0..<n { ref[i] = rnd() * 0.5 }                                          // 對方(系統音)
        for i in 0..<n { near[i] = 0.3 * sinf(2 * Float.pi * 700 * Float(i) / 48_000) }  // 你:純人聲,無回音
        let (_, peak) = DelayEstimator.estimate(near: near, ref: ref, maxLag: 12_000)
        let ok = peak < 0.10                                                             // 低於門檻 → gate 略過
        return Result(name: "AEC 無回音 gate(戴耳機略過)", passed: ok,
                      detail: String(format: "左右軌相關 %.3f < 0.10 → 略過 AEC", peak))
    }

    // MARK: - Helpers

    private static func makeMono(_ sampleRate: Double, _ frames: Int, _ value: Float) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let ch = buf.floatChannelData![0]
        for i in 0..<frames { ch[i] = value }
        return buf
    }

    private static func rms(_ buf: AVAudioPCMBuffer, _ channel: Int) -> Float {
        guard let data = buf.floatChannelData, Int(buf.format.channelCount) > channel else { return 0 }
        let n = Int(buf.frameLength); guard n > 0 else { return 0 }
        var sum: Float = 0; let ch = data[channel]
        for i in 0..<n { sum += ch[i] * ch[i] }
        return sqrt(sum / Float(n))
    }
}
