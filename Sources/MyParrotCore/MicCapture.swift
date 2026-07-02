import Foundation
import AVFoundation
import AudioToolbox

/// Captures "you" — the microphone — via AVAudioEngine.
/// Kept separate from the system tap so the Bluetooth headset can stay on A2DP
/// for listening while we record from the built-in / wired mic.
///
/// `@unchecked Sendable`: all control (start/stop/rebuild) is confined to the main
/// thread — the owner (RecordingController, @MainActor) calls start/stop, and the
/// configuration-change observer is delivered on `OperationQueue.main`. The tap block
/// only *reads* `gain`/`onLevel`/`onBuffer`, which are set once before `start()`. So no
/// shared mutable state is concurrently written; the marker just lets the @Sendable
/// notification closure capture `self` (PKG-10).
final class MicCapture: @unchecked Sendable {

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var gain: Float = 1.0

    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    /// The device this engine is pinned to (nil = system default). Remembered so the
    /// configuration-change self-heal can re-pin the same device (AUD-27 / BUG-18).
    private var deviceID: AudioDeviceID?
    private var configObserver: NSObjectProtocol?

    /// Optional specific input device; nil = system default input.
    func start(deviceID: AudioDeviceID? = nil) throws {
        guard !isRunning else { return }
        self.deviceID = deviceID
        try buildAndStart()
        isRunning = true
        observeConfigurationChange()
    }

    /// Pin the device, read the *current* hardware format, install the tap and start.
    /// Reused by `start()` and by the configuration-change self-heal — both must read a
    /// FRESH format: after a device/route change `outputFormat(forBus:)` only reflects the
    /// new device once the audio unit has renegotiated its stream description.
    private func buildAndStart() throws {
        let input = engine.inputNode
        if let deviceID, let au = input.audioUnit {
            var dev = deviceID
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &dev,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw "麥克風不可用" }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if self.gain != 1.0 { buffer.scale(by: self.gain) }
            self.onLevel?(buffer.rmsLevel)
            self.onBuffer?(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    /// AUD-27 / BUG-18: when the input hardware's channel count or sample rate changes
    /// (a meeting app grabs/switches the default input, Bluetooth flips A2DP↔HFP, a device
    /// is un/replugged), AVAudioEngine **stops and uninitializes itself** and posts this
    /// notification — it does NOT auto-restart. Left unhandled, the engine stays dead and
    /// the tap delivers nothing → 你軌 goes permanently silent until the user manually
    /// switches mics. So we rebuild the tap with the now-current format and restart.
    ///
    /// Apple's docs warn the engine must not be torn down synchronously inside the
    /// notification's internal dispatch queue (it DEADLOCKS). Delivering on
    /// `OperationQueue.main` runs the rebuild on the main thread instead — decoupled from
    /// that internal queue — which both avoids the deadlock and keeps all engine control
    /// main-confined.
    private func observeConfigurationChange() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.rebuildAfterConfigurationChange()
        }
    }

    private func rebuildAfterConfigurationChange() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // If the new format isn't ready yet (0 Hz) this throws; we keep `isRunning` true
        // and let the controller's liveness watchdog (AUD-28) retry / fall back.
        try? buildAndStart()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    deinit { stop() }
}

extension AVAudioPCMBuffer {
    /// Apply input gain `g`, then a soft-knee limiter so high gain can't push the
    /// signal past ±1 and clip ("破音"). Linear below ±0.9, smoothly compressed above.
    func scale(by g: Float) {
        guard let data = floatChannelData else { return }
        let n = Int(frameLength)
        let knee: Float = 0.9, span: Float = 0.1   // span = 1 - knee
        for c in 0..<Int(format.channelCount) {
            let ch = data[c]
            for i in 0..<n {
                let v = ch[i] * g
                if v > knee { ch[i] = knee + span * tanhf((v - knee) / span) }
                else if v < -knee { ch[i] = -knee - span * tanhf((-v - knee) / span) }
                else { ch[i] = v }
            }
        }
    }
}
