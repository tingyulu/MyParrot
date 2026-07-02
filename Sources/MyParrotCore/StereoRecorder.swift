import Foundation
import AVFoundation

/// Muxes the two capture sources into one stereo file:
///   left channel  = 對方 (system audio)
///   right channel = 你   (microphone)
/// Recording each speaker on its own channel is what gives MyParrot free,
/// reliable "who said what" without expensive diarization.
///
/// NOTE (v1.1 TODO): the two sources run on independent clocks. This MVP uses a
/// simple drain loop with silence padding; long meetings may drift. Sample-accurate
/// sync / drift correction is a known follow-up.
final class StereoRecorder: @unchecked Sendable {

    private let sampleRate: Double = 48_000
    private let format: AVAudioFormat

    private let leftQueue = SampleQueue()   // 對方
    private let rightQueue = SampleQueue()  // 你
    private let leftConv = MonoDownconverter()
    private let rightConv = MonoDownconverter()

    private var file: AVAudioFile?
    private var timer: DispatchSourceTimer?
    private let drainQueue = DispatchQueue(label: "MyParrot.StereoRecorder", qos: .userInitiated)

    private(set) var isRecording = false
    var isPaused = false
    /// First-buffer flags for head-start alignment (AUD-29): whichever side starts
    /// late gets that much leading silence so both channels keep a common t0 under
    /// min()-paced draining. Plain vars like isPaused — worst-case race is one
    /// buffer (~10–85 ms) of alignment slack, same as the old tick quantization.
    private var leftStarted = false
    private var rightStarted = false
    /// Jitter tolerance before a stalled side gets padded: 0.3 s @48k. Routine
    /// scheduling jitter (mic tap blocks arrive ~85 ms apart) stays far below this,
    /// so normal recording never pads; a genuinely dead side (BUG-18) still does.
    private static let maxLag = 14_400

    init() {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: sampleRate,
                               channels: 2,
                               interleaved: false)!
    }

    func start(url: URL) throws {
        guard !isRecording else { return }
        leftQueue.clear(); rightQueue.clear()
        leftStarted = false; rightStarted = false
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        isPaused = false
        isRecording = true

        let t = DispatchSource.makeTimerSource(queue: drainQueue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    func feedSystem(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, !isPaused else { return }
        if !leftStarted {
            leftStarted = true
            // 你 already flowing → this side is late by the other queue's backlog;
            // lead with that much silence to keep a common t0 (AUD-29).
            let lead = rightQueue.count
            if lead > 0 { leftQueue.append([Float](repeating: 0, count: lead)) }
        }
        leftQueue.append(leftConv.convert(buffer))
    }

    func feedMic(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, !isPaused else { return }
        if !rightStarted {
            rightStarted = true
            let lead = leftQueue.count
            if lead > 0 { rightQueue.append([Float](repeating: 0, count: lead)) }
        }
        rightQueue.append(rightConv.convert(buffer))
    }

    private func drain() {
        guard isRecording, !isPaused, let file else { return }
        let l = leftQueue.count, r = rightQueue.count
        let ready = min(l, r)
        let backlog = max(l, r)
        // AUD-29 / BUG-19: draining max() used to zero-pad the momentarily-slower
        // queue on every tick (three unsynchronized clocks: mic tap ~85 ms, system
        // IOProc ~10 ms, this 100 ms timer) — measured 2,171 mid-speech zero gaps
        // in one 23-min recording, each a hard-step click. Drain the *common*
        // length instead so routine jitter never pads; only a genuinely stalled
        // side (dead mic, BUG-18) gets ramped padding, and 對方 keeps being written
        // (one side dying mid-meeting must never take the other track with it).
        let chunk: Int
        if ready == 0, backlog > Self.maxLag {
            chunk = min(backlog, Int(sampleRate))   // stalled side → ramped padding
        } else {
            chunk = min(ready, Int(sampleRate))     // common length → no padding
        }
        guard chunk > 0 else { return }

        let left = leftQueue.drain(chunk)
        let right = rightQueue.drain(chunk)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)),
              let ch = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(chunk)
        for i in 0..<chunk {
            ch[0][i] = left[i]
            ch[1][i] = right[i]
        }
        try? file.write(from: buffer)
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        timer?.cancel(); timer = nil
        drainQueue.sync { drainRemaining() }
        file = nil
    }

    private func drainRemaining() {
        guard let file else { return }
        while leftQueue.count > 0 || rightQueue.count > 0 {
            let n = min(max(leftQueue.count, rightQueue.count), Int(sampleRate))
            if n == 0 { break }
            let left = leftQueue.drain(n)
            let right = rightQueue.drain(n)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let ch = buffer.floatChannelData else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { ch[0][i] = left[i]; ch[1][i] = right[i] }
            try? file.write(from: buffer)
        }
    }
}
