import Foundation
import AudioToolbox
import AVFoundation
import os

/// Captures the "other party" audio — everything the system plays — via a global
/// Core Audio Process Tap (macOS 14.4+). No virtual driver, bot-free.
/// Emits the tap's native-format buffers; conversion/mux happens in StereoRecorder.
final class SystemAudioCapture {

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let queue = DispatchQueue(label: "MyParrot.SystemAudioCapture", qos: .userInitiated)

    private var tapID = AudioObjectID.unknown
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

    // Ground-truth rate measurement (runs on `queue` inside the IOProc).
    private var rateFrames = 0
    private var rateWindowStart: UInt64 = 0
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()
    private static let commonRates: [Double] = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000]

    private(set) var isRunning = false

    /// Process object IDs to exclude from the tap (e.g. our own app to avoid echo).
    var excludedProcesses: [AudioObjectID] = []

    func start() throws {
        guard !isRunning else { return }

        // Global tap of all system output, optionally excluding given processes.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted   // keep playing in the user's ears
        desc.isPrivate = true

        var newTap = AudioObjectID.unknown
        var err = AudioHardwareCreateProcessTap(desc, &newTap)
        guard err == noErr else { throw "Process tap creation failed (\(err))" }
        tapID = newTap

        let outputID = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try outputID.readDeviceUID()

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

        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, _, _, _ in
            guard let self, let fmt = self.tapFormat else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inInputData, deallocator: nil) else { return }
            self.measureRate(frames: Int(buffer.frameLength))   // ground-truth rate correction
            self.onLevel?(buffer.rmsLevel)
            self.onBuffer?(buffer)
        }

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, ioBlock)
        guard err == noErr else { throw "Failed to create IOProc (\(err))" }

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { throw "Failed to start device (\(err))" }

        isRunning = true
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

    func stop() {
        // BUG-22 審查發現:guard 曾經是 `isRunning`,但 `start()` 中途失敗時
        // (tap/aggregate 已建立、`AudioDeviceStart` 或更後面才拋錯)`isRunning`
        // 還沒被設成 true,導致這裡整段清理被跳過 → tap/aggregate 永久洩漏。
        // 自動重建(rebuildSystemCapture)一旦重試中反覆撞到這個縫,每次失敗都
        // 會洩漏一組真的 CoreAudio process tap + aggregate device。改用
        // tapID/aggregateID 是否有效判斷,不管 isRunning 有沒有真的翻過。
        guard isRunning || tapID.isValid || aggregateID.isValid else { return }
        isRunning = false
        rateWindowStart = 0; rateFrames = 0
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

    deinit { stop() }
}
