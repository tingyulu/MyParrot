import Foundation
import AudioToolbox
import AVFoundation
import os

/// Captures the "other party" audio — everything the system plays — via a global
/// Core Audio Process Tap (macOS 14.4+). No virtual driver, bot-free.
/// Emits the tap's native-format buffers; conversion/mux happens in StereoRecorder.
///
/// AUD-39(#2529／BUG-35):建／拆 process tap＋aggregate 在藍牙狀態變動時會等 HAL(真機 R3 重連時
/// 主執行緒 1.4 s),所以 start／stop 搬到專用序列佇列 `controlQueue`、完成回 main;`stop()` 呼叫當下
/// 翻 `muted`,IOProc 立刻丟 buffer。tap／aggregate／IOProc id 等狀態只在 `controlQueue` 上讀寫;
/// IOProc 跑在自己的 `queue`(既有)。`@unchecked Sendable` 由這個佇列紀律保證。
/// PERM-05(#2673):對方軌目標輸出裝置的傳輸類型快照。
enum OutputTransport: Sendable, Equatable {
    case bluetooth, other, unknown
}

final class SystemAudioCapture: @unchecked Sendable {

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

    /// AUD-39:start／stop 的序列佇列(與 IOProc 的 `queue` 分開)。
    private static let controlQueue = DispatchQueue(label: "tw.uncle.MyParrot.sys-capture", qos: .userInitiated)
    /// stop() 一呼叫就翻 true,IOProc 第一行就丟 buffer;start 在佇列上翻回 false。
    private let muted = OSAllocatedUnfairLock(initialState: false)
    /// AUD-39 D(G3):每次 `stop()` 當下遞增;`start` 入列時記下,輪到它時世代變了(中間又被 stop)就取消,
    /// 不把 muted 翻回 false。
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    private let queue = DispatchQueue(label: "MyParrot.SystemAudioCapture", qos: .userInitiated)

    private var tapID = AudioObjectID.unknown
    /// AUD-40:建 aggregate 時用的那顆**真實輸出裝置**(不是 aggregate);看門狗判死前查它是否在跑。controlQueue-confined。
    private var outputDeviceID = AudioObjectID.unknown
    /// PERM-05(#2673):目標輸出裝置的傳輸類型(HFP 只發生在藍牙輸出)。在 `controlQueue` 上跟 `outputDeviceID` 一起讀、
    /// 一起清;main 只讀這個快照決定對方軌無聲警告的文案(藍牙 ⇒ HFP 說法;其他 ⇒ 請確認播放／可能是權限)。
    /// 二審:tap 還沒建好、建失敗、讀不到、輸出切換到重建完成之間都是 `.unknown` ⇒ 用舊的 HFP 文案、不推論權限(lock 只保證讀寫安全,不保證新鮮)。
    private let outputTransportLock = OSAllocatedUnfairLock(initialState: OutputTransport.unknown)
    var outputTransport: OutputTransport { outputTransportLock.withLock { $0 } }
    private var aggregateID = AudioObjectID.unknown
    private var inputStreamID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?

    /// Channel layout + flags from the tap. The RATE field is overridden with the
    /// MEASURED transaction rate — see `applyRate(_:)` / `measureRate(frames:)`.
    private var tapASBD: AudioStreamBasicDescription?
    /// Format used to wrap each delivered buffer. Built from the tap's channel layout
    /// with the sample rate set to the rate the IOProc *actually* delivers, measured
    /// from delivered-frames ÷ wall-clock. Core Audio's published rates (tap format,
    /// device nominal rate, even the input stream's "virtual format") all report the
    /// A2DP rate (48 kHz) and do NOT reflect a Bluetooth device dropping to HFP 24 kHz
    /// mid-capture, which mislabels buffers → pitch-/speed-doubled 對方 (BUG-15). The
    /// measured rate is the only source immune to that. Read+written only on `queue`
    /// (the IOProc runs there, and `applyRate` is only called from the IOProc/start).
    private var tapFormat: AVAudioFormat?

    /// BUG-25 gap-fill state (read/written only on `queue`, inside the IOProc).
    /// Device-clock sample time where the NEXT callback should start; <0 = unseeded.
    private var nextExpectedSampleTime: Double = -1
    /// Total frames of silence inserted this run — surfaced for diagnostics/tests.
    private(set) var gapFramesFilled = 0

    /// Missing-frame count between callbacks, per the device clock. Ignores sub-32
    /// jitter (timestamp rounding), refuses >2 s (device switch / rebuild — the sample
    /// timeline is no longer continuous; resync instead of flooding silence), and
    /// refuses negative/unseeded (first callback, or clock restart).
    static func gapFrames(expected: Double, now: Double,
                          minGap: Int = 32, maxGap: Int = 96_000) -> Int {
        guard expected >= 0 else { return 0 }
        let gap = Int((now - expected).rounded())
        guard gap > minGap, gap <= maxGap else { return 0 }
        return gap
    }

    /// Zeroed PCM buffer in the tap's format (all channels), for gap filling.
    static func silenceBuffer(format: AVAudioFormat, frames: Int) -> AVAudioPCMBuffer? {
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        for c in 0..<Int(format.channelCount) { ch[c].update(repeating: 0, count: frames) }
        return buf
    }

    // Ground-truth rate measurement (runs on `queue` inside the IOProc).
    private var rateFrames = 0
    private var rateWindowStart: UInt64 = 0
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()
    private static let commonRates: [Double] = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000]

    private(set) var isRunning = false

    /// Extra process object IDs to exclude from the tap (on top of our own process).
    var excludedProcesses: [AudioObjectID] = []
    /// BUG-29(#2411):the exclusion list actually handed to the tap on the last `start()`
    /// (own process + `excludedProcesses`), for logging / verification.
    private(set) var activeExclusions: [AudioObjectID] = []

    /// pid → Core Audio process object。`CoreAudioUtils` 早就有 `translatePIDToProcessObject`
    /// (註解寫「used to exclude our own audio」),只是從來沒人呼叫——BUG-29 就是這個洞。
    /// 行程還沒碰過音訊時可能沒有物件(回 nil);我們在 mic 之後才開 tap,所以正常有。
    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        guard let id = try? AudioObjectID.translatePIDToProcessObject(pid), id.isValid else { return nil }
        return id
    }

    /// 純函式:最終排除清單＝自己的 process object(有的話)＋額外清單,去重。
    static func exclusionList(own: AudioObjectID?, extra: [AudioObjectID]) -> [AudioObjectID] {
        var out: [AudioObjectID] = []
        for id in (own.map { [$0] } ?? []) + extra where id != AudioObjectID.unknown && !out.contains(id) { out.append(id) }
        return out
    }

    /// AUD-39:非阻塞啟動;在 `controlQueue` 上建 tap＋aggregate＋IOProc,完成(成功 nil／失敗 error)回 main。
    /// 失敗時已清乾淨(BUG-22:半途失敗也要拆掉已建的 tap／aggregate)。
    func start(completion: @escaping @Sendable (Error?) -> Void) {
        let gen = generation.withLock { $0 }
        SystemAudioCapture.controlQueue.async { [self] in
            guard gen == generation.withLock({ $0 }) else {
                DispatchQueue.main.async { completion("對方軌啟動已取消(排隊期間被停止)") }
                return
            }
            muted.withLock { $0 = false }
            do {
                try startOnQueue()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                teardown()
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// AUD-39:非阻塞停止;呼叫當下靜音,拆除在 `controlQueue` 上做,做完(有給 completion 才)回 main。
    func stop(completion: (@Sendable () -> Void)? = nil) {
        muted.withLock { $0 = true }
        generation.withLock { $0 += 1 }   // G3:排在後面的 start 作廢
        SystemAudioCapture.controlQueue.async { [self] in
            teardown()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// AUD-40(BUG-36):目標輸出裝置是否有人在跑 IO(`kAudioDevicePropertyDeviceIsRunningSomewhere`)。
    /// 整台 Mac 沒聲音在播時輸出裝置閒置、tap 不送 buffer,跟 tap 死掉用 buffer 流量分不出來,看門狗判死前先問這個。
    /// 在 `controlQueue` 上讀(藍牙裝置轉換時讀裝置屬性會卡,不在 main 讀);讀不到回 nil。結果回 main。
    func checkOutputRunning(completion: @escaping @Sendable (Bool?) -> Void) {
        SystemAudioCapture.controlQueue.async { [self] in
            let t0 = DispatchTime.now()
            let result = Self.isRunningSomewhere(outputDeviceID)
            os_log("MyParrot sys: 輸出裝置 %u IsRunningSomewhere=%{public}@ %ldms", outputDeviceID,
                   result.map { $0 ? "1" : "0" } ?? "nil", Self.ms(since: t0))
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func isRunningSomewhere(_ dev: AudioObjectID) -> Bool? {
        guard dev.isValid else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let st = AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &value)
        return st == noErr ? (value != 0) : nil
    }

    /// 既有的同步建立流程,只在 `controlQueue` 上跑。
    private func startOnQueue() throws {
        dispatchPrecondition(condition: .onQueue(SystemAudioCapture.controlQueue))
        // AUD-39 M1:建 tap＋aggregate＋IOProc 的耗時(成功或失敗都記;真機對主執行緒回應迴圈用)。
        let t0 = DispatchTime.now()
        var ok = false
        defer { os_log("MyParrot sys: start %ldms ok=%ld", Self.ms(since: t0), ok ? 1 : 0) }
        guard !isRunning else { ok = true; return }

        // Global tap of all system output, excluding OUR OWN process (so playing back a
        // recording or monitoring the mic through the speakers is not captured into 對方
        // — BUG-29) plus any extra processes the caller listed.
        let own = Self.processObject(forPID: ProcessInfo.processInfo.processIdentifier)
        activeExclusions = Self.exclusionList(own: own, extra: excludedProcesses)
        if own == nil { Logger(subsystem: "tw.uncle.MyParrot", category: "capture").notice("own process has no audio object; tap will not exclude self") }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: activeExclusions)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted   // keep playing in the user's ears
        desc.isPrivate = true

        var newTap = AudioObjectID.unknown
        var err = AudioHardwareCreateProcessTap(desc, &newTap)
        guard err == noErr else { throw "Process tap creation failed (\(err))" }
        tapID = newTap

        let outputID = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try outputID.readDeviceUID()
        outputDeviceID = outputID   // AUD-40
        // PERM-05:先讀起來,整條(aggregate／IOProc／start)都成功才 commit;中途 throw 由 start() 的 teardown 清回 unknown(二審第二輪)。
        let transport: OutputTransport = (try? outputID.read(kAudioDevicePropertyTransportType, defaultValue: UInt32(0)))
            .map { $0 == kAudioDeviceTransportTypeBluetooth || $0 == kAudioDeviceTransportTypeBluetoothLE ? .bluetooth : .other } ?? .unknown

        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MyParrot-SystemTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString
            ]]
        ]

        // Keep the tap's channel layout/flags; the rate is corrected by measurement.
        tapASBD = try tapID.readAudioTapStreamBasicDescription()

        var newAggregate = AudioObjectID.unknown
        err = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &newAggregate)
        guard err == noErr else { throw "Aggregate device creation failed (\(err))" }
        aggregateID = newAggregate
        inputStreamID = (try? aggregateID.readInputStreamID()) ?? .unknown

        // Seed with the best published guess; measurement takes over within ~0.4 s.
        queue.sync { applyRate(seedRate()) }
        guard tapFormat != nil else { throw "Failed to build AVAudioFormat from tap" }

        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, inInputTime, _, _ in
            guard let self else { return }
            if self.muted.withLock({ $0 }) { return }   // AUD-39:stop() 當下就不再送 buffer
            guard let fmt = self.tapFormat else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inInputData, deallocator: nil) else { return }
            // BUG-25:藍牙輸出當時鐘主時,藍牙重傳/抖動會讓 IOProc 漏拍——漏掉的樣本
            // 從未送達,左軌波形被「跳接」,一場 30 分鐘可累積數十萬個爆點(BUG-25 實例
            // 4.95% 樣本)。缺口只在這裡看得到(裝置時鐘 mSampleTime vs 實際送達幀數),
            // 到 StereoRecorder 已無從得知。補法:偵測到缺口就原地補等長靜音,時間軸
            // 對齊、爆裂跳接變成可辨的短靜音。非藍牙裝置不漏拍 → 天生 no-op。
            let ts = inInputTime.pointee
            var frames = Int(buffer.frameLength)
            if ts.mFlags.contains(.sampleTimeValid) {
                let gap = Self.gapFrames(expected: self.nextExpectedSampleTime, now: ts.mSampleTime)
                if gap > 0, let filler = Self.silenceBuffer(format: fmt, frames: gap) {
                    self.gapFramesFilled += gap
                    frames += gap                    // 缺口屬於裝置時間軸,計入測速才準
                    self.onLevel?(0)
                    self.onBuffer?(filler)
                }
                self.nextExpectedSampleTime = ts.mSampleTime + Double(buffer.frameLength)
            }
            self.measureRate(frames: frames)   // ground-truth rate correction
            self.onLevel?(buffer.rmsLevel)
            self.onBuffer?(buffer)
        }

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, ioBlock)
        guard err == noErr else { throw "Failed to create IOProc (\(err))" }

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { throw "Failed to start device (\(err))" }

        isRunning = true
        outputTransportLock.withLock { $0 = transport }   // PERM-05:到這裡才算建好
        ok = true
    }

    private static func ms(since t: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- t.uptimeNanoseconds) / 1_000_000)
    }

    /// Best published guess for the initial rate: input-stream virtual format → device
    /// nominal rate → tap format. Often wrong for Bluetooth/HFP (all report A2DP 48 kHz),
    /// which is exactly why `measureRate` overrides it from the real data flow.
    private func seedRate() -> Double {
        if inputStreamID.isValid, let vf = try? inputStreamID.readStreamVirtualFormat(), vf.mSampleRate > 0 {
            return vf.mSampleRate
        }
        if aggregateID.isValid, let r = try? aggregateID.readNominalSampleRate(), r > 0 { return r }
        return tapASBD?.mSampleRate ?? 48_000
    }

    /// Measure the real delivered rate (frames ÷ wall-clock) over ~0.4 s windows and
    /// relabel `tapFormat` when it changes. Runs on `queue` (inside the IOProc), so it
    /// shares one serial queue with every `tapFormat` read/write — no race. frameLength
    /// is rate-independent (byteCount ÷ bytesPerFrame), so it's a true frame count even
    /// while the format is mislabeled.
    private func measureRate(frames: Int) {
        let now = mach_absolute_time()
        if rateWindowStart == 0 { rateWindowStart = now; rateFrames = frames; return }
        rateFrames += frames
        let elapsedNs = (now &- rateWindowStart) &* UInt64(Self.timebase.numer) / UInt64(Self.timebase.denom)
        guard elapsedNs >= 400_000_000 else { return }            // ~0.4 s window
        let measured = Double(rateFrames) / (Double(elapsedNs) / 1e9)
        rateWindowStart = now; rateFrames = 0
        guard measured > 4_000, measured < 200_000 else { return }  // ignore garbage windows
        let snapped = Self.commonRates.min(by: { abs($0 - measured) < abs($1 - measured) }) ?? measured
        if abs(snapped - (tapFormat?.sampleRate ?? 0)) > 1 {
            applyRate(snapped)
        }
    }

    /// Rebuild `tapFormat` = tap channel layout + `rate`. Only on `queue`.
    private func applyRate(_ rate: Double) {
        guard var asbd = tapASBD, rate > 0 else { return }
        let prev = tapFormat?.sampleRate ?? asbd.mSampleRate
        asbd.mSampleRate = rate
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { return }
        tapFormat = fmt
        if Int(prev) != Int(rate) {
            os_log("MyParrot: 對方 (system audio) capture rate %{public}.0f → %{public}.0f Hz — the published device rate misreports under Bluetooth/HFP; corrected from the measured data flow",
                   prev, rate)
        }
    }

    /// 既有的同步拆除流程。由 `stop(completion:)`／`start` 失敗在 `controlQueue` 上呼叫;`deinit` 也用它
    /// (deinit 時沒有別的參考、佇列上不會有排著的工作,不必上佇列)。
    private func teardown() {
        // BUG-22 審查發現:guard 曾經是 `isRunning`,但 `start()` 中途失敗時
        // (tap/aggregate 已建立、`AudioDeviceStart` 或更後面才拋錯)`isRunning`
        // 還沒被設成 true,導致這裡整段清理被跳過 → tap/aggregate 永久洩漏。
        // 自動重建(rebuildSystemCapture)一旦重試中反覆撞到這個縫,每次失敗都
        // 會洩漏一組真的 CoreAudio process tap + aggregate device。改用
        // tapID/aggregateID 是否有效判斷,不管 isRunning 有沒有真的翻過。
        guard isRunning || tapID.isValid || aggregateID.isValid else { return }
        // AUD-39 M1:拆 IOProc＋aggregate＋tap 的耗時。
        let t0 = DispatchTime.now()
        defer { os_log("MyParrot sys: stop %ldms", Self.ms(since: t0)) }
        isRunning = false
        outputDeviceID = .unknown   // AUD-40
        outputTransportLock.withLock { $0 = .unknown }   // PERM-05:拆掉就不知道了(重建完成前不推論)
        rateWindowStart = 0; rateFrames = 0
        nextExpectedSampleTime = -1; gapFramesFilled = 0   // BUG-25: sample timeline resets with the tap
        inputStreamID = .unknown

        if aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            procID = nil
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    deinit { teardown() }
}
