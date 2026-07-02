import Foundation
import Accelerate

/// Reference-based acoustic echo canceller (NLMS adaptive filter).
///
/// We uniquely have the far-end reference: the system audio we captured (對方).
/// This estimates the speaker→mic echo path and subtracts the predicted echo from
/// the near-end mic (你). Pure DSP — does NOT touch macOS voice processing, so it
/// never ducks system output the way `setVoiceProcessingEnabled` did.
///
/// Mono, single sample rate. Feed near (mic) and ref (system) blocks that are
/// roughly time-aligned; the adaptive filter learns the exact echo delay within
/// its `taps`-sample tail. State persists across calls so it can run in chunks.
final class EchoCanceller {
    private let taps: Int
    private let mu: Float          // NLMS step size (0<mu<2)
    private let eps: Float = 1e-6
    private var w: [Float]         // echo-path estimate (oldest..newest)
    private var buf: [Float]       // ref history, double-length for a contiguous window
    private var end: Int           // one-past-newest index into buf
    private var refMax: Float = 0  // decaying peak of |ref| for double-talk detection
    private let dtThresh: Float    // Geigel: near > dtThresh·refMax ⇒ near-end speech
    private let holdSamples: Int   // keep frozen this long after detecting double-talk
    private var dtHold = 0

    init(taps: Int = 1024, mu: Float = 0.3, doubleTalkThreshold: Float = 0.5, holdSamples: Int = 2_400) {
        self.taps = taps
        self.mu = mu
        self.dtThresh = doubleTalkThreshold
        self.holdSamples = holdSamples
        w = [Float](repeating: 0, count: taps)
        buf = [Float](repeating: 0, count: taps * 2)
        end = taps
    }

    /// Returns echo-reduced near-end. `near` and `ref` should be the same length.
    func process(near: [Float], ref: [Float]) -> [Float] {
        let n = min(near.count, ref.count)
        var out = [Float](repeating: 0, count: n)
        let N = vDSP_Length(taps)
        w.withUnsafeMutableBufferPointer { wp in
            buf.withUnsafeMutableBufferPointer { bp in
                let wb = wp.baseAddress!
                let bb = bp.baseAddress!
                for i in 0..<n {
                    bb[end] = ref[i]
                    let start = end - taps + 1          // window = bb[start ... end]
                    let win = bb + start
                    var est: Float = 0
                    vDSP_dotpr(wb, 1, win, 1, &est, N)
                    let e = near[i] - est               // cleaned sample
                    out[i] = e
                    // Double-talk: if the near-end is louder than the far-end echo
                    // could be, the user is speaking — freeze adaptation so their
                    // voice doesn't corrupt the converged echo-path estimate.
                    refMax = max(abs(ref[i]), refMax * 0.9995)
                    if abs(near[i]) > dtThresh * refMax + 1e-4 { dtHold = holdSamples }
                    if dtHold > 0 {
                        dtHold -= 1                       // frozen (double-talk hangover)
                    } else {
                        // NLMS: w += mu * e * win / (||win||^2 + eps)
                        var energy: Float = 0
                        vDSP_svesq(win, 1, &energy, N)
                        var step = mu * e / (energy + eps)
                        vDSP_vsma(win, 1, &step, wb, 1, wb, 1, N)
                    }
                    end += 1
                    if end == taps * 2 {                // compact: keep last `taps`
                        for k in 0..<taps { bb[k] = bb[taps + k] }
                        end = taps
                    }
                }
            }
        }
        return out
    }
}
